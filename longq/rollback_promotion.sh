#!/bin/bash
# Put the stock UltraStar Deluxe 2026.2.0 back at /Applications/UltraStarDeluxe.app (ours goes to the backup dir, nothing deleted).
B="$HOME/.local/state/ultrastar_backup"; pgrep -x ultrastardx >/dev/null && { echo "quit UltraStar first"; exit 1; }; mv /Applications/UltraStarDeluxe.app "$B/app_longq_rolled_back_$(date +%Y%m%d%H%M%S).app" && mv "$B/app_2026.2.0/UltraStarDeluxe.app" /Applications/UltraStarDeluxe.app && echo "stock 2026.2.0 restored (config/scores untouched; pre-promotion copies in $B/promotion_20261109)"
