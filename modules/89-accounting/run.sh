#!/usr/bin/env bash
# DESC: usage accounting: job ids, who ran what and for how long, CPU-hours per project (hpc-acct)
# Needs 88-tenants to have run (it parses the flat file). See docs/accounting.md.
. "$HPC_ROOT/lib/common.sh"
a=$(admin_host)
node_put "$a" "$HPC_ROOT/tools/hpc-acct.py" /usr/local/sbin/hpc-acct 0755
node_run "$a" "$HPC_MODULE_DIR/node/install.sh"
ok "accounting recorder running on $a; admin tool: bin/hpcctl acct status"
