"""Read the production tool definitions owned by preinstalled Pace powers."""

import re
from pathlib import Path


def read_tool_definitions(project_directory: Path) -> list[tuple[str, str, str]]:
    source_directory = project_directory / "leanring-buddy"
    registry_source = (source_directory / "PaceToolRegistry.swift").read_text()
    kind_body = registry_source.split("enum PaceLocalToolKind:", 1)[1].split("\n}", 1)[0]
    kind_order = re.findall(r"^\s*case (\w+)\s*$", kind_body, re.MULTILINE)
    definitions = {}
    for path in sorted((source_directory / "Powers").glob("*/*Power.swift")):
        for block in re.findall(r"PaceLocalToolDefinition\(.*?\n        \)", path.read_text(), re.DOTALL):
            kind = re.search(r"kind:\s*\.(\w+),", block)[1]
            name = re.search(r'canonicalName:\s*"([^"]+)"', block)[1]
            schema = re.search(r'schemaExample:\s*#"(.*?)"#', block, re.DOTALL)[1]
            description = re.search(r'description:\s*"(.*?)"', block, re.DOTALL)[1]
            if kind in definitions:
                raise ValueError(f"Duplicate Pace tool owner for {kind}")
            definitions[kind] = (name, schema, description)
    if set(kind_order) != set(definitions):
        raise ValueError("Pace power tool definitions do not match the typed tool kinds")
    return [definitions[kind] for kind in kind_order]
