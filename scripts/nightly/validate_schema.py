#!/usr/bin/env python3
# =============================================================================
# scripts/nightly/validate_schema.py
# =============================================================================
# Validates JSON files against JSON Schema Draft 2020-12 schemas.
# =============================================================================

import sys
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

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: validate_schema.py <instance_path> <schema_path>")
        sys.exit(1)

    instance_file = sys.argv[1]
    schema_file = sys.argv[2]
    success = validate_instance(instance_file, schema_file)
    sys.exit(0 if success else 1)
