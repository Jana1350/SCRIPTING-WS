#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test_alerts.sh"
sandbox
export FAKE_TABLE="$temp/table"
cat > "$temp/bin/crontab" <<'FAKE'
#!/usr/bin/env bash
set -eu
if [[ $1 == -l ]]; then
    if [[ -e $FAKE_TABLE.error ]]; then echo "read failure" >&2; exit 1; fi
    if [[ ! -f $FAKE_TABLE ]]; then echo "no crontab for $(id -un)" >&2; exit 1; fi
    cat "$FAKE_TABLE"
else
    cp "$1" "$FAKE_TABLE"
    echo write >> "$FAKE_TABLE.writes"
fi
FAKE
chmod +x "$temp/bin/crontab"
[[ $(command -v crontab) == "$temp/bin/crontab" ]]
cron=$repo/scripts/setup_cron.sh
expect 0 "$cron"
cp "$temp/stdout" "$temp/preview"
[[ ! -e $FAKE_TABLE && ! -e $repo/runtime ]]
expect 7 "$cron" --install
for f in main.sh report.sh rotate_logs.sh; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$repo/scripts/$f"
    chmod +x "$repo/scripts/$f"
done
expect 0 "$cron" --install
cmp "$FAKE_TABLE" "$temp/preview"
[[ $(wc -l < "$FAKE_TABLE") == 6 ]]
! grep -Fq '%' "$FAKE_TABLE" || exit 1
# Exercise the shell commands from the preview using only fixture A/C commands.
for n in 2 3 4 5; do
    command_line=$(sed -n "${n}p" "$FAKE_TABLE" | cut -d' ' -f6-)
    /bin/sh -c "$command_line"
done
diff -u <(printf '%s\n' --once daily weekly '') "$repo/runtime/cron.log"
before='# existing comment'
after='0 4 * * * /bin/true'
{ echo "$before"; cat "$temp/preview"; echo "$after"; } > "$FAKE_TABLE"
cp "$FAKE_TABLE" "$temp/installed"
expect 0 "$cron" --install
cmp "$FAKE_TABLE" "$temp/installed"
[[ $(wc -l < "$FAKE_TABLE.writes") == 1 ]]
expect 0 "$cron" --uninstall
diff -u <(printf '%s\n' "$before" "$after") "$FAKE_TABLE"
expect 0 "$cron" --uninstall
[[ $(wc -l < "$FAKE_TABLE.writes") == 2 ]]
expect 0 "$cron" --install
expect 0 "$cron" --install
expect 0 "$cron" --uninstall
diff -u <(printf '%s\n' "$before" "$after") "$FAKE_TABLE"
for malformed in begin end duplicate; do
    case $malformed in
        begin) head -1 "$temp/preview" > "$FAKE_TABLE";;
        end) tail -1 "$temp/preview" > "$FAKE_TABLE";;
        duplicate) cat "$temp/preview" "$temp/preview" > "$FAKE_TABLE";;
    esac
    cp "$FAKE_TABLE" "$temp/original"
    expect 4 "$cron" --install
    expect 4 "$cron" --uninstall
    cmp "$FAKE_TABLE" "$temp/original"
done
touch "$FAKE_TABLE.error"
expect 4 "$cron" --install
cmp "$FAKE_TABLE" "$temp/original"
echo 'PASS cron preview, scheduled command quoting, preservation, idempotence and unsafe table refusal'
