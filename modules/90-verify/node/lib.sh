# tiny test harness shared by the verify node scripts
pass=0; failed=0
t()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass=$((pass+1)); printf '    PASS  %s\n' "$d"; else failed=$((failed+1)); printf '    FAIL  %s\n' "$d"; fi; }
tn() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then failed=$((failed+1)); printf '    FAIL  %s\n' "$d"; else pass=$((pass+1)); printf '    PASS  %s\n' "$d"; fi; }
# tm <description> <expected-substring> <command...>: command output must contain the text
tm() { local d="$1" want="$2" out; shift 2; out=$("$@" 2>&1 || true)
       if grep -qF -- "$want" <<<"$out"; then pass=$((pass+1)); printf '    PASS  %s\n' "$d"
       else failed=$((failed+1)); printf '    FAIL  %s\n          got: %s\n' "$d" "$(head -c 300 <<<"$out" | tr '\n' ' ')"; fi; }
summary() { printf '    %d passed, %d failed\n' "$pass" "$failed"; [ "$failed" -eq 0 ]; }
