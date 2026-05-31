#!/bin/bash -e
# Run the DXVK recovery test under Wine / Winlator
# Usage: ./run_test.sh [inject_frame]
#   inject_frame: submit number to inject VK_ERROR_DEVICE_LOST (default: 100)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INJECT="${1:-100}"

echo "=== DXVK Recovery Test ==="
echo "Inject VK_ERROR_DEVICE_LOST at submit #$INJECT"
echo ""

# Set up paths: DLLs go alongside the .exe
cp -v "$SCRIPT_DIR/../../2.7.1-arm64ec-gplasync.wcp.xz_placeholder" 2>/dev/null || true

# Tell DXVK where to log
export DXVK_LOG_LEVEL=info
export DXVK_DEBUG_DEVICE_LOST="$INJECT"

echo "Running..."
echo ""

# Under Wine/Winlator:
# WINEDLLOVERRIDES="d3d9,dxgi,d3d11,d3d10core=n,b" wine test_recovery.exe
# Then check test_recovery.log

echo "Expected log output (test_recovery.log):"
echo "  DXVK: Injecting synthetic DEVICE_LOST at submit $INJECT"
echo "  frame 95: OK"
echo "  frame 100: OK"
echo "  frame 105: OK"
echo "  DXVK_RECOVERY_TEST done: failures=0/2000"
echo ""
echo "Without the fix, output stops at frame ~98 with:"
echo "  DxvkSubmissionQueue: Command submission failed: VK_ERROR_DEVICE_LOST"
echo "  ... repeated spam ..."
echo ""
echo "To run the test:"
echo "  cd $SCRIPT_DIR && WINEDLLOVERRIDES='d3d9,dxgi,d3d11,d3d10core=n,b' wine test_recovery.exe"
echo "  cat test_recovery.log"
