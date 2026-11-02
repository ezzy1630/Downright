#!/usr/bin/env python3
"""Exercise the packaged worker within the host's actual five-second deadline."""
from pathlib import Path
import subprocess
import sys
import time
import xml.etree.ElementTree as ET


def main():
    worker = Path(sys.argv[1]).resolve()
    examples = [
        ("Alice -> Bob: Rendered locally\nBob --> Alice: Done", ["Alice", "Bob", "Rendered locally"]),
        ("\n".join(f"class Entity{i}\nEntity{i} --> Entity{i + 1}" for i in range(12)), ["Entity0", "Entity12"]),
        ("start\n:Read document;\n:Render diagram;\nstop", ["Read document", "Render diagram"]),
    ]
    for dark in (False, True):
        for index, (body, labels) in enumerate(examples):
            source = f"@startuml\n{body}\n@enduml\n"
            started = time.monotonic()
            result = subprocess.run(
                [str(worker), "--downright-render-plantuml" + ("-dark" if dark else "")],
                input=source.encode(), capture_output=True, timeout=5, check=True,
                env={"PATH": "/usr/bin:/bin"},
            )
            if not 0 < len(result.stdout) <= 1_048_576:
                raise ValueError("worker output exceeds its contract")
            svg = ET.fromstring(result.stdout)
            text = " ".join(svg.itertext())
            if svg.tag != "{http://www.w3.org/2000/svg}svg" or any(label not in text for label in labels):
                raise ValueError("worker did not produce the requested diagram")
            print(f"PlantUML packaged worker: {'dark' if dark else 'light'} case {index + 1}, "
                  f"{time.monotonic() - started:.3f}s", flush=True)


if __name__ == "__main__":
    main()
