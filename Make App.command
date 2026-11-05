#!/bin/bash
# Double-click in Finder to build Card Ingest and put it in Applications.
cd "$(dirname "$0")"
if scripts/make-app.sh; then
    echo
    echo "Finished. You can close this window."
else
    echo
    echo "It didn't finish, and the app in Applications wasn't changed. See the message above."
fi
read -n 1 -s -r -p "Press any key to close."
echo
