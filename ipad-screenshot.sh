#!/bin/bash
# Take screenshot on iPad and copy to local machine
# Usage: ipad-screenshot.sh [output_path]

OUTPUT="${1:-$HOME/Desktop/ipad_$(date +%Y%m%d_%H%M%S).png}"

echo "Taking screenshot on iPad..."

# Trigger screenshot via activator
ssh mini5 "activator send libactivator.system.take-screenshot" 2>/dev/null

# Wait for screenshot to be saved
sleep 2

# Get the latest screenshot (using ls -t for sorting by time)
LATEST=$(ssh mini5 'ls -t /var/mobile/Media/DCIM/100APPLE/*.PNG 2>/dev/null | head -1')

if [ -z "$LATEST" ]; then
    echo "No screenshot found"
    exit 1
fi

echo "Copying: $LATEST"
scp "mini5:$LATEST" "$OUTPUT" 2>/dev/null

if [ $? -eq 0 ]; then
    echo "Saved to: $OUTPUT"
    open "$OUTPUT" 2>/dev/null
else
    echo "Failed to copy"
    exit 1
fi
