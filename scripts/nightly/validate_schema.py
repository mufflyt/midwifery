#!/usr/bin/env python3
# =============================================================================
# scripts/nightly/validate_schema.py
# =============================================================================
# Validates JSON files against JSON Schema Draft 2020-12 schemas.
# =============================================================================

import sys
import os
import json
import jsonschema

def validate_instance(instance_path, schema_path):
    with open(schema_path, 'r', encoding='utf-8') as sf:
        schema = json.load(sf)
    with open(instance_path, 'r', encoding='utf-8') as inf:
        instance = json.load(inf)

    try:
        jsonschema.validate(instance=instance, schema=schema)
        print(f"VALID: {instance_path} conforms to schema {schema_path}")
        return True
    except jsonschema.exceptions.ValidationError as e:
        print(f"INVALID: {instance_path} fails schema {schema_path}: {e.message}")
        return False
    except Exception as e:
        print(f"ERROR validating {instance_path}: {e}")
        return False

def validate_jsonl(jsonl_path, schema_path):
    with open(schema_path, 'r', encoding='utf-8') as sf:
        schema = json.load(sf)
    if not os.path.exists(jsonl_path):
        print(f"SKIP: {jsonl_path} does not exist.")
        return True
    valid = True
    with open(jsonl_path, 'r', encoding='utf-8') as inf:
        for idx, line in enumerate(inf, 1):
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
                jsonschema.validate(instance=record, schema=schema)
            except jsonschema.exceptions.ValidationError as e:
                print(f"INVALID: {jsonl_path} line {idx} fails schema {schema_path}: {e.message}")
                valid = False
            except Exception as e:
                print(f"ERROR line {idx} in {jsonl_path}: {e}")
                valid = False
    if valid:
        print(f"VALID: {jsonl_path} (all JSONL lines) conform to schema {schema_path}")
    return valid

def validate_all(artifacts_dir="artifacts/nightly", schemas_dir="config/nightly/schemas"):
    pairs = [
        (os.path.join(artifacts_dir, "run_manifest.json"), os.path.join(schemas_dir, "run-manifest.schema.json"), False),
        (os.path.join(artifacts_dir, "sentinel_summary.json"), os.path.join(schemas_dir, "sentinel-summary.schema.json"), False),
        (os.path.join(artifacts_dir, "sentinel_events.jsonl"), os.path.join(schemas_dir, "sentinel-event.schema.json"), True),
    ]
    all_ok = True
    for inst, sch, is_jsonl in pairs:
        if is_jsonl:
            if not validate_jsonl(inst, sch):
                all_ok = False
        else:
            if not validate_instance(inst, sch):
                all_ok = False
    return all_ok

if __name__ == "__main__":
    if len(sys.argv) == 3:
        instance_file = sys.argv[1]
        schema_file = sys.argv[2]
        success = validate_instance(instance_file, schema_file)
    elif len(sys.argv) in (1, 2):
        art_dir = sys.argv[1] if len(sys.argv) == 2 else "artifacts/nightly"
        success = validate_all(artifacts_dir=art_dir)
    else:
        print("Usage: validate_schema.py [artifacts_dir] OR validate_schema.py <instance_path> <schema_path>")
        sys.exit(1)

    sys.exit(0 if success else 1)
