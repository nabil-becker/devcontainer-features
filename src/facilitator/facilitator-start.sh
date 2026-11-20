#!/usr/bin/env bash
# facilitator-start: the post-start hook. Participant tokens are made again (they are valid for this
# container start only, the ADR-0048 exception), then, when autostart is on, the infrastructure is
# started: the Directory, the SLIM node and the facilitator's ssh-agent. Never fatal, and never starts
# a participant.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
"$here/facilitator" start || echo "facilitator: start did not complete; run facilitator check"
exit 0
