import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXAMPLES = (
    ROOT / "examples" / "python" / "basic_replay.py",
    ROOT / "examples" / "python" / "explicit_copy_buffer.py",
    ROOT / "examples" / "python" / "mlx_unsupported_status.py",
)


def test_python_examples_run_from_source_checkout():
    for example in EXAMPLES:
        result = subprocess.run(
            [sys.executable, str(example)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip()
