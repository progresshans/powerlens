"""Typed schema and policy evaluation for PowerLens system-API probes."""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum
from typing import Any


SUPPORTED_PROFILE_SCHEMA_VERSION = 2
SUPPORTED_PROBE_SCHEMA_VERSION = 2
SANITIZED_TYPE_NAMES = frozenset(
    {
        "array",
        "boolean",
        "data",
        "dictionary",
        "number",
        "other",
        "string",
    }
)
METHOD_STATES = frozenset(
    {"compatible", "missing", "incompatible", "notInspected"}
)
KEY_STATES = frozenset({"available", "keyMissing", "notAttempted"})
SMC_KEY_STATES = frozenset(
    {"available", "keyMissing", "notAttempted", "readFailed", "typeMismatch"}
)
SMC_CONNECTION_STATES = frozenset(
    {"available", "unavailable", "accessFailed"}
)
DISPATCH_KINDS = frozenset({"classMethod", "instanceMethod"})
PRESENCE_POLICIES = frozenset({"optional", "requiredWhenContainerAvailable"})
POWER_UI_CLASSIFICATIONS = frozenset(
    {
        "compatible",
        "optionalCapabilityMissing",
        "environmentUnavailable",
        "transientFailure",
        "contractMismatch",
        "invalidResponse",
    }
)
POWER_UI_REASON_CODES = frozenset(
    {
        "none",
        "frameworkLoadFailed",
        "clientClassMissing",
        "methodMissing",
        "methodSignatureMismatch",
        "initializationFailed",
        "queryFailed",
        "invalidManualChargeLimit",
    }
)
POWER_UI_REASON_BY_CLASSIFICATION = {
    "compatible": frozenset({"none"}),
    "optionalCapabilityMissing": frozenset({"methodMissing"}),
    "environmentUnavailable": frozenset({"initializationFailed"}),
    "transientFailure": frozenset({"queryFailed"}),
    "contractMismatch": frozenset(
        {
            "frameworkLoadFailed",
            "clientClassMissing",
            "methodMissing",
            "methodSignatureMismatch",
        }
    ),
    "invalidResponse": frozenset({"invalidManualChargeLimit"}),
}
THREE_COMPONENT_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
MINIMUM_SYSTEM_VERSION = re.compile(r"^[0-9]+\.[0-9]+(?:\.[0-9]+)?$")


class VerificationMode(str, Enum):
    HOSTED = "hosted"
    PHYSICAL = "physical"


class SchemaError(ValueError):
    pass


@dataclass(frozen=True)
class MethodContract:
    selector: str
    dispatch: str
    expected_return_types: tuple[str, ...]
    expected_argument_types: tuple[str, ...]


@dataclass(frozen=True)
class OptionalCapability:
    name: str
    availability_rule: str
    methods: tuple[MethodContract, ...]


@dataclass(frozen=True)
class KeyContract:
    path: str
    allowed_types: tuple[str, ...]
    presence: str


@dataclass(frozen=True)
class SMCKeyContract:
    key: str
    expected_data_type: str
    expected_data_size: int
    presence: str


@dataclass(frozen=True)
class DictionaryHardwareContract:
    required_in_physical_mode: bool
    keys: tuple[KeyContract, ...]


@dataclass(frozen=True)
class SMCHardwareContract:
    required_in_physical_mode: bool
    keys: tuple[SMCKeyContract, ...]


@dataclass(frozen=True)
class ContractProfile:
    profile_schema_version: int
    profile_name: str
    probe_schema_version: int
    host_macos_major_version: int
    architecture: str
    minimum_macos_version: str
    required_methods: tuple[MethodContract, ...]
    optional_capabilities: tuple[OptionalCapability, ...]
    runtime_policies: dict[VerificationMode, frozenset[str]]
    io_power_sources: DictionaryHardwareContract
    external_power_adapter: DictionaryHardwareContract
    apple_smart_battery: DictionaryHardwareContract
    apple_smc: SMCHardwareContract


@dataclass(frozen=True)
class MethodObservation:
    selector: str
    dispatch: str
    expected_return_types: tuple[str, ...]
    expected_argument_types: tuple[str, ...]
    state: str
    actual_type_encoding: str | None


@dataclass(frozen=True)
class RuntimeObservation:
    subsystem: str
    classification: str
    reason: str
    component: str | None
    expected_type_encoding: str | None
    actual_type_encoding: str | None
    error_domain: str | None
    error_code: int | None
    observed_integer: int | None


@dataclass(frozen=True)
class KeyObservation:
    path: str
    state: str
    observed_type: str | None


@dataclass(frozen=True)
class SMCKeyObservation:
    key: str
    state: str
    observed_data_type: str | None
    observed_data_size: int | None


@dataclass(frozen=True)
class ProbeReport:
    schema_version: int
    operating_system_version: str
    operating_system_build: str
    architecture: str
    app_version: str
    app_build: str
    minimum_macos_version: str
    powerui_framework_loaded: bool
    powerui_client_class_found: bool | None
    powerui_methods: tuple[MethodObservation, ...]
    runtime_observation: RuntimeObservation
    iops_info_available: bool
    iops_source_count: int
    iops_first_description_available: bool
    iops_keys: tuple[KeyObservation, ...]
    adapter_dictionary_available: bool
    adapter_keys: tuple[KeyObservation, ...]
    battery_service_available: bool
    battery_properties_readable: bool
    battery_keys: tuple[KeyObservation, ...]
    smc_service_available: bool
    smc_connection_state: str
    smc_keys: tuple[SMCKeyObservation, ...]


@dataclass(frozen=True)
class VerificationResult:
    errors: tuple[str, ...]
    warnings: tuple[str, ...]

    @property
    def succeeded(self) -> bool:
        return not self.errors


def _child(path: str, field: str) -> str:
    return field if path == "$" else f"{path}.{field}"


def _object(
    value: Any,
    path: str,
    *,
    required: set[str],
    optional: set[str] | None = None,
) -> dict[str, Any]:
    if type(value) is not dict:
        raise SchemaError(f"{path}: expected object")
    optional = optional or set()
    missing = sorted(required - value.keys())
    if missing:
        raise SchemaError(f"{_child(path, missing[0])}: missing required field")
    unknown = sorted(value.keys() - required - optional)
    if unknown:
        raise SchemaError(f"{_child(path, unknown[0])}: unknown field")
    return value


def _array(value: Any, path: str) -> list[Any]:
    if type(value) is not list:
        raise SchemaError(f"{path}: expected array")
    return value


def _string(value: Any, path: str, *, available: bool = False) -> str:
    if type(value) is not str:
        raise SchemaError(f"{path}: expected string")
    if not value.strip() or (available and not _is_available_string(value)):
        raise SchemaError(f"{path}: expected available non-empty string")
    return value


def _integer(value: Any, path: str, *, minimum: int | None = None) -> int:
    if type(value) is not int:
        raise SchemaError(f"{path}: expected integer")
    if minimum is not None and value < minimum:
        raise SchemaError(f"{path}: expected integer >= {minimum}")
    return value


def _boolean(value: Any, path: str) -> bool:
    if type(value) is not bool:
        raise SchemaError(f"{path}: expected boolean")
    return value


def _string_array(
    value: Any,
    path: str,
    *,
    allowed: frozenset[str] | None = None,
    nonempty: bool = True,
    unique: bool = False,
) -> tuple[str, ...]:
    values = _array(value, path)
    if nonempty and not values:
        raise SchemaError(f"{path}: expected non-empty array")
    parsed = tuple(
        _string(item, f"{path}[{index}]")
        for index, item in enumerate(values)
    )
    if unique and len(set(parsed)) != len(parsed):
        raise SchemaError(f"{path}: duplicate values are not allowed")
    if allowed is not None:
        invalid = next((item for item in parsed if item not in allowed), None)
        if invalid is not None:
            raise SchemaError(f"{path}: unsupported value {invalid!r}")
    return parsed


def _optional_string(
    value: dict[str, Any], key: str, path: str
) -> str | None:
    item = value.get(key)
    if item is None:
        return None
    return _string(item, _child(path, key))


def _optional_integer(
    value: dict[str, Any], key: str, path: str
) -> int | None:
    item = value.get(key)
    if item is None:
        return None
    return _integer(item, _child(path, key))


def _is_available_string(value: Any) -> bool:
    return (
        type(value) is str
        and bool(value.strip())
        and value.strip().casefold() != "unknown"
    )


def _parse_method_contract(value: Any, path: str) -> MethodContract:
    value = _object(
        value,
        path,
        required={
            "selector",
            "dispatch",
            "expectedReturnTypes",
            "expectedArgumentTypes",
        },
    )
    dispatch = _string(value["dispatch"], _child(path, "dispatch"))
    if dispatch not in DISPATCH_KINDS:
        raise SchemaError(f"{_child(path, 'dispatch')}: unsupported dispatch")
    return MethodContract(
        selector=_string(value["selector"], _child(path, "selector")),
        dispatch=dispatch,
        expected_return_types=_string_array(
            value["expectedReturnTypes"],
            _child(path, "expectedReturnTypes"),
            unique=True,
        ),
        expected_argument_types=_string_array(
            value["expectedArgumentTypes"],
            _child(path, "expectedArgumentTypes"),
        ),
    )


def _parse_method_observation(value: Any, path: str) -> MethodObservation:
    value = _object(
        value,
        path,
        required={
            "selector",
            "dispatch",
            "expectedReturnTypes",
            "expectedArgumentTypes",
            "state",
        },
        optional={"actualTypeEncoding"},
    )
    state = _string(value["state"], _child(path, "state"))
    if state not in METHOD_STATES:
        raise SchemaError(f"{_child(path, 'state')}: unsupported method state")
    actual = _optional_string(value, "actualTypeEncoding", path)
    if state in {"compatible", "incompatible"} and actual is None:
        raise SchemaError(
            f"{_child(path, 'actualTypeEncoding')}: required for {state} state"
        )
    if state in {"missing", "notInspected"} and actual is not None:
        raise SchemaError(
            f"{_child(path, 'actualTypeEncoding')}: forbidden for {state} state"
        )
    dispatch = _string(value["dispatch"], _child(path, "dispatch"))
    if dispatch not in DISPATCH_KINDS:
        raise SchemaError(f"{_child(path, 'dispatch')}: unsupported dispatch")
    return MethodObservation(
        selector=_string(value["selector"], _child(path, "selector")),
        dispatch=dispatch,
        expected_return_types=_string_array(
            value["expectedReturnTypes"],
            _child(path, "expectedReturnTypes"),
            unique=True,
        ),
        expected_argument_types=_string_array(
            value["expectedArgumentTypes"],
            _child(path, "expectedArgumentTypes"),
        ),
        state=state,
        actual_type_encoding=actual,
    )


def _parse_key_contract(value: Any, path: str) -> KeyContract:
    value = _object(
        value,
        path,
        required={"path", "allowedTypes", "presence"},
    )
    presence = _string(value["presence"], _child(path, "presence"))
    if presence not in PRESENCE_POLICIES:
        raise SchemaError(f"{_child(path, 'presence')}: unsupported policy")
    key_path = _string(value["path"], _child(path, "path"))
    if any(not component for component in key_path.split(".")):
        raise SchemaError(f"{_child(path, 'path')}: invalid dotted key path")
    return KeyContract(
        path=key_path,
        allowed_types=_string_array(
            value["allowedTypes"],
            _child(path, "allowedTypes"),
            allowed=SANITIZED_TYPE_NAMES,
            unique=True,
        ),
        presence=presence,
    )


def _parse_key_observation(value: Any, path: str) -> KeyObservation:
    value = _object(
        value,
        path,
        required={"path", "state"},
        optional={"observedType"},
    )
    state = _string(value["state"], _child(path, "state"))
    if state not in KEY_STATES:
        raise SchemaError(f"{_child(path, 'state')}: unsupported key state")
    observed_type = _optional_string(value, "observedType", path)
    if observed_type is not None and observed_type not in SANITIZED_TYPE_NAMES:
        raise SchemaError(
            f"{_child(path, 'observedType')}: unsupported sanitized type"
        )
    if state == "available" and observed_type is None:
        raise SchemaError(
            f"{_child(path, 'observedType')}: required for available state"
        )
    if state != "available" and observed_type is not None:
        raise SchemaError(
            f"{_child(path, 'observedType')}: forbidden for {state} state"
        )
    return KeyObservation(
        path=_string(value["path"], _child(path, "path")),
        state=state,
        observed_type=observed_type,
    )


def _parse_smc_key_contract(value: Any, path: str) -> SMCKeyContract:
    value = _object(
        value,
        path,
        required={
            "key",
            "expectedDataType",
            "expectedDataSize",
            "presence",
        },
    )
    data_type = _string(
        value["expectedDataType"], _child(path, "expectedDataType")
    )
    if len(data_type.encode("utf-8")) != 4:
        raise SchemaError(
            f"{_child(path, 'expectedDataType')}: expected four-byte code"
        )
    presence = _string(value["presence"], _child(path, "presence"))
    if presence not in PRESENCE_POLICIES:
        raise SchemaError(f"{_child(path, 'presence')}: unsupported policy")
    key = _string(value["key"], _child(path, "key"))
    if len(key.encode("utf-8")) != 4:
        raise SchemaError(f"{_child(path, 'key')}: expected four-byte key")
    return SMCKeyContract(
        key=key,
        expected_data_type=data_type,
        expected_data_size=_integer(
            value["expectedDataSize"],
            _child(path, "expectedDataSize"),
            minimum=1,
        ),
        presence=presence,
    )


def _parse_smc_key_observation(value: Any, path: str) -> SMCKeyObservation:
    value = _object(
        value,
        path,
        required={"key", "state"},
        optional={"observedDataType", "observedDataSize"},
    )
    state = _string(value["state"], _child(path, "state"))
    if state not in SMC_KEY_STATES:
        raise SchemaError(f"{_child(path, 'state')}: unsupported SMC key state")
    data_type = _optional_string(value, "observedDataType", path)
    data_size = _optional_integer(value, "observedDataSize", path)
    if (data_type is None) != (data_size is None):
        raise SchemaError(f"{path}: SMC type and size must be reported together")
    if data_type is not None and len(data_type.encode("utf-8")) != 4:
        raise SchemaError(
            f"{_child(path, 'observedDataType')}: expected four-byte code"
        )
    if data_size is not None and data_size < 1:
        raise SchemaError(
            f"{_child(path, 'observedDataSize')}: expected positive integer"
        )
    if state in {"available", "typeMismatch"} and data_type is None:
        raise SchemaError(f"{path}: {state} state requires observed SMC type")
    if state in {"keyMissing", "notAttempted"} and data_type is not None:
        raise SchemaError(f"{path}: {state} state forbids observed SMC type")
    key = _string(value["key"], _child(path, "key"))
    if len(key.encode("utf-8")) != 4:
        raise SchemaError(f"{_child(path, 'key')}: expected four-byte key")
    return SMCKeyObservation(
        key=key,
        state=state,
        observed_data_type=data_type,
        observed_data_size=data_size,
    )


def _parse_dictionary_hardware_contract(
    value: Any, path: str
) -> DictionaryHardwareContract:
    value = _object(
        value,
        path,
        required={"requiredInPhysicalMode", "keys"},
    )
    keys = tuple(
        _parse_key_contract(item, f"{path}.keys[{index}]")
        for index, item in enumerate(_array(value["keys"], f"{path}.keys"))
    )
    if not keys:
        raise SchemaError(f"{path}.keys: expected non-empty array")
    _require_unique((item.path for item in keys), f"{path}.keys")
    return DictionaryHardwareContract(
        required_in_physical_mode=_boolean(
            value["requiredInPhysicalMode"],
            f"{path}.requiredInPhysicalMode",
        ),
        keys=keys,
    )


def _require_unique(values: Any, path: str) -> None:
    seen: set[str] = set()
    for value in values:
        if value in seen:
            raise SchemaError(f"{path}: duplicate value {value!r}")
        seen.add(value)


def parse_profile(value: Any) -> ContractProfile:
    root = _object(
        value,
        "$",
        required={
            "profileSchemaVersion",
            "profileName",
            "probeSchemaVersion",
            "host",
            "app",
            "powerUI",
            "hardware",
        },
    )
    profile_schema_version = _integer(
        root["profileSchemaVersion"], "profileSchemaVersion"
    )
    if profile_schema_version != SUPPORTED_PROFILE_SCHEMA_VERSION:
        raise SchemaError(
            "profileSchemaVersion: unsupported contract profile schema version"
        )

    host = _object(
        root["host"],
        "host",
        required={"macOSMajorVersion", "architecture"},
    )
    app = _object(
        root["app"],
        "app",
        required={"minimumMacOSVersion"},
    )
    powerui = _object(
        root["powerUI"],
        "powerUI",
        required={"requiredMethods", "optionalCapabilities", "runtimePolicies"},
    )
    required_methods = tuple(
        _parse_method_contract(item, f"powerUI.requiredMethods[{index}]")
        for index, item in enumerate(
            _array(powerui["requiredMethods"], "powerUI.requiredMethods")
        )
    )
    if not required_methods:
        raise SchemaError("powerUI.requiredMethods: expected non-empty array")

    capabilities: list[OptionalCapability] = []
    for index, item in enumerate(
        _array(
            powerui["optionalCapabilities"],
            "powerUI.optionalCapabilities",
        )
    ):
        path = f"powerUI.optionalCapabilities[{index}]"
        item = _object(
            item,
            path,
            required={"name", "availabilityRule", "methods"},
        )
        rule = _string(item["availabilityRule"], f"{path}.availabilityRule")
        if rule != "allOrNone":
            raise SchemaError(
                f"{path}.availabilityRule: only allOrNone is supported"
            )
        methods = tuple(
            _parse_method_contract(method, f"{path}.methods[{method_index}]")
            for method_index, method in enumerate(
                _array(item["methods"], f"{path}.methods")
            )
        )
        if not methods:
            raise SchemaError(f"{path}.methods: expected non-empty array")
        capabilities.append(
            OptionalCapability(
                name=_string(item["name"], f"{path}.name"),
                availability_rule=rule,
                methods=methods,
            )
        )

    _require_unique((item.name for item in capabilities), "optional capabilities")
    all_methods = list(required_methods)
    for capability in capabilities:
        all_methods.extend(capability.methods)
    _require_unique((item.selector for item in all_methods), "PowerUI selectors")

    runtime_policies_value = _object(
        powerui["runtimePolicies"],
        "powerUI.runtimePolicies",
        required={mode.value for mode in VerificationMode},
    )
    runtime_policies: dict[VerificationMode, frozenset[str]] = {}
    for mode in VerificationMode:
        path = f"powerUI.runtimePolicies.{mode.value}"
        policy = _object(
            runtime_policies_value[mode.value],
            path,
            required={"allowedClassifications"},
        )
        runtime_policies[mode] = frozenset(
            _string_array(
                policy["allowedClassifications"],
                f"{path}.allowedClassifications",
                allowed=POWER_UI_CLASSIFICATIONS,
                unique=True,
            )
        )

    hardware = _object(
        root["hardware"],
        "hardware",
        required={
            "ioPowerSources",
            "externalPowerAdapter",
            "appleSmartBattery",
            "appleSMC",
        },
    )
    smc_value = _object(
        hardware["appleSMC"],
        "hardware.appleSMC",
        required={"requiredInPhysicalMode", "keys"},
    )
    smc_keys = tuple(
        _parse_smc_key_contract(item, f"hardware.appleSMC.keys[{index}]")
        for index, item in enumerate(
            _array(smc_value["keys"], "hardware.appleSMC.keys")
        )
    )
    if not smc_keys:
        raise SchemaError("hardware.appleSMC.keys: expected non-empty array")
    _require_unique((item.key for item in smc_keys), "hardware.appleSMC.keys")

    probe_schema_version = _integer(
        root["probeSchemaVersion"], "probeSchemaVersion"
    )
    if probe_schema_version != SUPPORTED_PROBE_SCHEMA_VERSION:
        raise SchemaError(
            "probeSchemaVersion: unsupported probe schema version"
        )
    minimum_macos_version = _string(
        app["minimumMacOSVersion"], "app.minimumMacOSVersion"
    )
    if not MINIMUM_SYSTEM_VERSION.fullmatch(minimum_macos_version):
        raise SchemaError(
            "app.minimumMacOSVersion: expected numeric version"
        )

    return ContractProfile(
        profile_schema_version=profile_schema_version,
        profile_name=_string(root["profileName"], "profileName"),
        probe_schema_version=probe_schema_version,
        host_macos_major_version=_integer(
            host["macOSMajorVersion"], "host.macOSMajorVersion", minimum=1
        ),
        architecture=_string(host["architecture"], "host.architecture"),
        minimum_macos_version=minimum_macos_version,
        required_methods=required_methods,
        optional_capabilities=tuple(capabilities),
        runtime_policies=runtime_policies,
        io_power_sources=_parse_dictionary_hardware_contract(
            hardware["ioPowerSources"], "hardware.ioPowerSources"
        ),
        external_power_adapter=_parse_dictionary_hardware_contract(
            hardware["externalPowerAdapter"],
            "hardware.externalPowerAdapter",
        ),
        apple_smart_battery=_parse_dictionary_hardware_contract(
            hardware["appleSmartBattery"],
            "hardware.appleSmartBattery",
        ),
        apple_smc=SMCHardwareContract(
            required_in_physical_mode=_boolean(
                smc_value["requiredInPhysicalMode"],
                "hardware.appleSMC.requiredInPhysicalMode",
            ),
            keys=smc_keys,
        ),
    )


def _parse_runtime_observation(value: Any, path: str) -> RuntimeObservation:
    optional = {
        "component",
        "expectedTypeEncoding",
        "actualTypeEncoding",
        "errorDomain",
        "errorCode",
        "observedInteger",
    }
    value = _object(
        value,
        path,
        required={"subsystem", "classification", "reason"},
        optional=optional,
    )
    classification = _string(
        value["classification"], _child(path, "classification")
    )
    reason = _string(value["reason"], _child(path, "reason"))
    if classification not in POWER_UI_CLASSIFICATIONS:
        raise SchemaError(f"{path}.classification: unsupported classification")
    if reason not in POWER_UI_REASON_CODES:
        raise SchemaError(f"{path}.reason: unsupported reason")
    return RuntimeObservation(
        subsystem=_string(value["subsystem"], _child(path, "subsystem")),
        classification=classification,
        reason=reason,
        component=_optional_string(value, "component", path),
        expected_type_encoding=_optional_string(
            value, "expectedTypeEncoding", path
        ),
        actual_type_encoding=_optional_string(value, "actualTypeEncoding", path),
        error_domain=_optional_string(value, "errorDomain", path),
        error_code=_optional_integer(value, "errorCode", path),
        observed_integer=_optional_integer(value, "observedInteger", path),
    )


def _parse_key_observation_array(value: Any, path: str) -> tuple[KeyObservation, ...]:
    return tuple(
        _parse_key_observation(item, f"{path}[{index}]")
        for index, item in enumerate(_array(value, path))
    )


def parse_report(value: Any) -> ProbeReport:
    root = _object(
        value,
        "$",
        required={
            "schemaVersion",
            "host",
            "app",
            "powerUI",
            "ioPowerSources",
            "externalPowerAdapter",
            "appleSmartBattery",
            "appleSMC",
        },
    )
    host = _object(
        root["host"],
        "host",
        required={
            "operatingSystemVersion",
            "operatingSystemBuild",
            "architecture",
        },
    )
    app = _object(
        root["app"],
        "app",
        required={"version", "build", "minimumMacOSVersion"},
    )
    powerui = _object(
        root["powerUI"],
        "powerUI",
        required={"frameworkLoaded", "methods", "runtimeObservation"},
        optional={"clientClassFound"},
    )
    client_class_found = powerui.get("clientClassFound")
    if client_class_found is not None:
        client_class_found = _boolean(
            client_class_found, "powerUI.clientClassFound"
        )

    iops = _object(
        root["ioPowerSources"],
        "ioPowerSources",
        required={
            "infoAvailable",
            "sourceCount",
            "firstDescriptionAvailable",
            "keys",
        },
    )
    adapter = _object(
        root["externalPowerAdapter"],
        "externalPowerAdapter",
        required={"dictionaryAvailable", "keys"},
    )
    battery = _object(
        root["appleSmartBattery"],
        "appleSmartBattery",
        required={"serviceAvailable", "propertiesReadable", "keys"},
    )
    smc = _object(
        root["appleSMC"],
        "appleSMC",
        required={"serviceAvailable", "connectionState", "keys"},
    )
    connection_state = _string(
        smc["connectionState"], "appleSMC.connectionState"
    )
    if connection_state not in SMC_CONNECTION_STATES:
        raise SchemaError("appleSMC.connectionState: unsupported state")

    return ProbeReport(
        schema_version=_integer(root["schemaVersion"], "schemaVersion"),
        operating_system_version=_string(
            host["operatingSystemVersion"], "host.operatingSystemVersion"
        ),
        operating_system_build=_string(
            host["operatingSystemBuild"],
            "host.operatingSystemBuild",
            available=True,
        ),
        architecture=_string(host["architecture"], "host.architecture"),
        app_version=_string(app["version"], "app.version", available=True),
        app_build=_string(app["build"], "app.build", available=True),
        minimum_macos_version=_string(
            app["minimumMacOSVersion"], "app.minimumMacOSVersion"
        ),
        powerui_framework_loaded=_boolean(
            powerui["frameworkLoaded"], "powerUI.frameworkLoaded"
        ),
        powerui_client_class_found=client_class_found,
        powerui_methods=tuple(
            _parse_method_observation(item, f"powerUI.methods[{index}]")
            for index, item in enumerate(
                _array(powerui["methods"], "powerUI.methods")
            )
        ),
        runtime_observation=_parse_runtime_observation(
            powerui["runtimeObservation"], "powerUI.runtimeObservation"
        ),
        iops_info_available=_boolean(
            iops["infoAvailable"], "ioPowerSources.infoAvailable"
        ),
        iops_source_count=_integer(
            iops["sourceCount"], "ioPowerSources.sourceCount", minimum=0
        ),
        iops_first_description_available=_boolean(
            iops["firstDescriptionAvailable"],
            "ioPowerSources.firstDescriptionAvailable",
        ),
        iops_keys=_parse_key_observation_array(
            iops["keys"], "ioPowerSources.keys"
        ),
        adapter_dictionary_available=_boolean(
            adapter["dictionaryAvailable"],
            "externalPowerAdapter.dictionaryAvailable",
        ),
        adapter_keys=_parse_key_observation_array(
            adapter["keys"], "externalPowerAdapter.keys"
        ),
        battery_service_available=_boolean(
            battery["serviceAvailable"],
            "appleSmartBattery.serviceAvailable",
        ),
        battery_properties_readable=_boolean(
            battery["propertiesReadable"],
            "appleSmartBattery.propertiesReadable",
        ),
        battery_keys=_parse_key_observation_array(
            battery["keys"], "appleSmartBattery.keys"
        ),
        smc_service_available=_boolean(
            smc["serviceAvailable"], "appleSMC.serviceAvailable"
        ),
        smc_connection_state=connection_state,
        smc_keys=tuple(
            _parse_smc_key_observation(item, f"appleSMC.keys[{index}]")
            for index, item in enumerate(_array(smc["keys"], "appleSMC.keys"))
        ),
    )


def _actual_encodings(contract: MethodContract) -> frozenset[str]:
    arguments = ",".join(contract.expected_argument_types)
    return frozenset(
        f"return={return_type};args={arguments}"
        for return_type in contract.expected_return_types
    )


def _evaluate_method(
    observed: MethodObservation,
    expected: MethodContract,
    errors: list[str],
) -> None:
    label = f"PowerUI selector {expected.selector}"
    if observed.dispatch != expected.dispatch:
        errors.append(f"{label} has the wrong dispatch kind")
    if observed.expected_return_types != expected.expected_return_types:
        errors.append(f"{label} changed expected return ABI")
    if observed.expected_argument_types != expected.expected_argument_types:
        errors.append(f"{label} changed expected argument ABI")
    if observed.state == "compatible" and (
        observed.actual_type_encoding not in _actual_encodings(expected)
    ):
        errors.append(f"{label} actual ABI does not match the profile")


def _observation_map(
    observations: tuple[KeyObservation, ...],
    label: str,
    errors: list[str],
) -> dict[str, KeyObservation]:
    result: dict[str, KeyObservation] = {}
    for observation in observations:
        if observation.path in result:
            errors.append(f"{label} duplicates key path {observation.path}")
        else:
            result[observation.path] = observation
    return result


def _evaluate_dictionary_keys(
    observations: tuple[KeyObservation, ...],
    contract: DictionaryHardwareContract,
    *,
    label: str,
    container_available: bool,
    errors: list[str],
) -> None:
    observed = _observation_map(observations, label, errors)
    expected = {item.path: item for item in contract.keys}
    if set(observed) != set(expected):
        missing = sorted(set(expected) - set(observed))
        extra = sorted(set(observed) - set(expected))
        if missing:
            errors.append(f"{label} is missing key observations: {', '.join(missing)}")
        if extra:
            errors.append(f"{label} has unexpected key observations: {', '.join(extra)}")

    if not container_available:
        invalid = sorted(
            item.path for item in observations if item.state != "notAttempted"
        )
        if invalid:
            errors.append(
                f"{label} reports attempted keys without an available container: "
                + ", ".join(invalid)
            )

    for path, key_contract in expected.items():
        item = observed.get(path)
        if item is None:
            continue
        parent_available = container_available
        if "." in path:
            parent_path = path.rsplit(".", maxsplit=1)[0]
            parent = observed.get(parent_path)
            parent_available = bool(
                container_available
                and parent is not None
                and parent.state == "available"
                and parent.observed_type == "dictionary"
            )
            if item.state != "notAttempted" and not parent_available:
                errors.append(
                    f"{label}.{path} was inspected while its parent is unavailable"
                )

        if item.state == "notAttempted" and parent_available:
            errors.append(
                f"{label}.{path} was not attempted despite an available container"
            )
        if (
            key_contract.presence == "requiredWhenContainerAvailable"
            and parent_available
            and item.state != "available"
        ):
            errors.append(f"{label}.{path} is required but unavailable")
        if (
            item.state == "available"
            and item.observed_type not in key_contract.allowed_types
        ):
            errors.append(
                f"{label}.{path} expected one of "
                f"{list(key_contract.allowed_types)!r}, got {item.observed_type!r}"
            )


def _hardware_unavailable(
    *,
    label: str,
    required: bool,
    mode: VerificationMode,
    errors: list[str],
    warnings: list[str],
) -> None:
    message = f"{label} is unavailable in {mode.value} mode"
    if mode is VerificationMode.PHYSICAL and required:
        errors.append(message)
    else:
        warnings.append(message)


def evaluate(
    report: ProbeReport,
    profile: ContractProfile,
    *,
    mode: VerificationMode,
    expected_app_version: str | None,
    expected_app_build: str | None,
) -> VerificationResult:
    errors: list[str] = []
    warnings: list[str] = []

    if report.schema_version != profile.probe_schema_version:
        errors.append("probe schema version does not match the contract profile")
    if not THREE_COMPONENT_VERSION.fullmatch(report.operating_system_version):
        errors.append("host operating-system version must be major.minor.patch")
    else:
        major = int(report.operating_system_version.split(".", maxsplit=1)[0])
        if major != profile.host_macos_major_version:
            errors.append("host macOS major version does not match the profile")
    if report.architecture != profile.architecture:
        errors.append("host architecture does not match the contract profile")
    if report.minimum_macos_version != profile.minimum_macos_version:
        errors.append("packaged app minimum macOS version is incorrect")
    if expected_app_version is not None and report.app_version != expected_app_version:
        errors.append("packaged app version does not match the expected value")
    if expected_app_build is not None and report.app_build != expected_app_build:
        errors.append("packaged app build does not match the expected value")

    if not report.powerui_framework_loaded:
        errors.append("PowerUI framework did not load")
    if report.powerui_client_class_found is not True:
        errors.append("PowerUISmartChargeClient was not found")

    methods: dict[str, MethodObservation] = {}
    for method in report.powerui_methods:
        if method.selector in methods:
            errors.append(f"PowerUI method report duplicates {method.selector}")
        else:
            methods[method.selector] = method
    expected_selectors = {
        item.selector for item in profile.required_methods
    } | {
        item.selector
        for capability in profile.optional_capabilities
        for item in capability.methods
    }
    if set(methods) != expected_selectors:
        missing = sorted(expected_selectors - set(methods))
        extra = sorted(set(methods) - expected_selectors)
        if missing:
            errors.append(
                "PowerUI method report is missing selectors: " + ", ".join(missing)
            )
        if extra:
            errors.append(
                "PowerUI method report has unexpected selectors: " + ", ".join(extra)
            )

    for contract in profile.required_methods:
        method = methods.get(contract.selector)
        if method is None:
            continue
        _evaluate_method(method, contract, errors)
        if method.state != "compatible":
            errors.append(f"PowerUI selector {contract.selector} is not ABI-compatible")

    unavailable_capabilities: list[str] = []
    all_capabilities_compatible = True
    for capability in profile.optional_capabilities:
        pairs = [
            (contract, methods.get(contract.selector))
            for contract in capability.methods
        ]
        for contract, method in pairs:
            if method is not None:
                _evaluate_method(method, contract, errors)
        states = [method.state for _, method in pairs if method is not None]
        if len(states) != len(pairs):
            all_capabilities_compatible = False
            continue
        if all(state == "missing" for state in states):
            all_capabilities_compatible = False
            unavailable_capabilities.append(capability.name)
            warnings.append(
                f"PowerUI optional capability {capability.name} is unavailable"
            )
        elif not all(state == "compatible" for state in states):
            all_capabilities_compatible = False
            errors.append(
                f"PowerUI optional capability {capability.name} must be all compatible or all missing"
            )

    runtime = report.runtime_observation
    runtime_reports_success = runtime.classification in {
        "compatible",
        "optionalCapabilityMissing",
    }
    # Runtime failures take precedence over an optional-capability diagnostic;
    # the method observations still preserve the capability's static absence.
    if (
        unavailable_capabilities
        and runtime_reports_success
        and runtime.classification != "optionalCapabilityMissing"
    ):
        errors.append(
            "PowerUI runtime observation must report optionalCapabilityMissing "
            "when an optional capability is absent"
        )
    if (
        all_capabilities_compatible
        and runtime.classification == "optionalCapabilityMissing"
    ):
        errors.append(
            "PowerUI runtime observation reports an optional capability "
            "missing while every capability is ABI-compatible"
        )
    if runtime.subsystem != "powerUI":
        errors.append("PowerUI runtime observation subsystem is invalid")
    if runtime.reason not in POWER_UI_REASON_BY_CLASSIFICATION[
        runtime.classification
    ]:
        errors.append(
            "PowerUI runtime observation classification and reason are incoherent"
        )
    if runtime.classification == "compatible":
        if any(
            value is not None
            for value in (
                runtime.component,
                runtime.expected_type_encoding,
                runtime.actual_type_encoding,
                runtime.error_domain,
                runtime.error_code,
                runtime.observed_integer,
            )
        ):
            errors.append("compatible PowerUI observation contains diagnostic details")
    else:
        if runtime.component is None:
            errors.append("non-compatible PowerUI observation requires a component")
    if runtime.reason == "methodSignatureMismatch":
        if runtime.expected_type_encoding is None:
            errors.append("method-signature mismatch requires expected ABI")
    elif runtime.expected_type_encoding is not None or runtime.actual_type_encoding is not None:
        errors.append("PowerUI ABI details are only valid for signature mismatches")
    if runtime.reason == "queryFailed":
        if runtime.error_domain is None or runtime.error_code is None:
            errors.append("PowerUI query failure requires error domain and code")
    elif runtime.error_domain is not None or runtime.error_code is not None:
        errors.append("PowerUI error details are only valid for query failures")
    if runtime.reason == "invalidManualChargeLimit":
        if runtime.observed_integer is None:
            errors.append("invalid manual charge limit requires observed integer")
    elif runtime.observed_integer is not None:
        errors.append("observed integer is only valid for invalid manual limit")

    if runtime.classification not in profile.runtime_policies[mode]:
        errors.append(
            f"PowerUI runtime classification {runtime.classification} is not allowed in {mode.value} mode"
        )
    elif runtime.classification != "compatible":
        warnings.append(
            "PowerUI runtime observation is "
            f"{runtime.classification} ({runtime.reason})"
        )

    if not report.iops_info_available:
        if report.iops_source_count != 0 or report.iops_first_description_available:
            errors.append("IOPowerSources availability fields are incoherent")
    if report.iops_first_description_available and (
        not report.iops_info_available or report.iops_source_count < 1
    ):
        errors.append("IOPowerSources description has no reported source")
    _evaluate_dictionary_keys(
        report.iops_keys,
        profile.io_power_sources,
        label="IOPowerSources",
        container_available=report.iops_first_description_available,
        errors=errors,
    )
    if not report.iops_first_description_available:
        _hardware_unavailable(
            label="IOPowerSources battery description",
            required=profile.io_power_sources.required_in_physical_mode,
            mode=mode,
            errors=errors,
            warnings=warnings,
        )

    _evaluate_dictionary_keys(
        report.adapter_keys,
        profile.external_power_adapter,
        label="externalPowerAdapter",
        container_available=report.adapter_dictionary_available,
        errors=errors,
    )
    if not report.adapter_dictionary_available:
        _hardware_unavailable(
            label="external power adapter dictionary",
            required=profile.external_power_adapter.required_in_physical_mode,
            mode=mode,
            errors=errors,
            warnings=warnings,
        )

    if report.battery_properties_readable and not report.battery_service_available:
        errors.append("AppleSmartBattery properties exist without a service")
    _evaluate_dictionary_keys(
        report.battery_keys,
        profile.apple_smart_battery,
        label="AppleSmartBattery",
        container_available=report.battery_properties_readable,
        errors=errors,
    )
    if not report.battery_properties_readable:
        _hardware_unavailable(
            label="AppleSmartBattery properties",
            required=profile.apple_smart_battery.required_in_physical_mode,
            mode=mode,
            errors=errors,
            warnings=warnings,
        )

    smc_observations: dict[str, SMCKeyObservation] = {}
    for item in report.smc_keys:
        if item.key in smc_observations:
            errors.append(f"AppleSMC duplicates key {item.key}")
        else:
            smc_observations[item.key] = item
    smc_contracts = {item.key: item for item in profile.apple_smc.keys}
    if set(smc_observations) != set(smc_contracts):
        missing = sorted(set(smc_contracts) - set(smc_observations))
        extra = sorted(set(smc_observations) - set(smc_contracts))
        if missing:
            errors.append("AppleSMC is missing key reports: " + ", ".join(missing))
        if extra:
            errors.append("AppleSMC has unexpected key reports: " + ", ".join(extra))
    if not report.smc_service_available:
        if report.smc_connection_state != "unavailable":
            errors.append("AppleSMC connection exists without a service")
    elif report.smc_connection_state == "unavailable":
        errors.append("AppleSMC service is available but connection is unavailable")
    connection_available = report.smc_connection_state == "available"
    for key, contract in smc_contracts.items():
        item = smc_observations.get(key)
        if item is None:
            continue
        if not connection_available and item.state != "notAttempted":
            errors.append(f"AppleSMC {key} was attempted without a connection")
        if connection_available and item.state == "notAttempted":
            errors.append(f"AppleSMC {key} was not attempted with a connection")
        if item.state == "typeMismatch":
            errors.append(f"AppleSMC {key} reports an incompatible data type")
        if item.observed_data_type is not None and (
            item.observed_data_type != contract.expected_data_type
            or item.observed_data_size != contract.expected_data_size
        ):
            errors.append(f"AppleSMC {key} data type does not match the profile")
        if (
            contract.presence == "requiredWhenContainerAvailable"
            and connection_available
            and item.state != "available"
        ):
            errors.append(f"AppleSMC {key} is required but unavailable")
        elif item.state in {"keyMissing", "readFailed"}:
            warnings.append(f"AppleSMC {key} is {item.state}")

    if not connection_available:
        _hardware_unavailable(
            label="AppleSMC connection",
            required=profile.apple_smc.required_in_physical_mode,
            mode=mode,
            errors=errors,
            warnings=warnings,
        )

    return VerificationResult(tuple(errors), tuple(dict.fromkeys(warnings)))


def verify_report(
    report_value: Any,
    profile_value: Any,
    *,
    mode: str | VerificationMode,
    expected_app_version: str | None = None,
    expected_app_build: str | None = None,
) -> VerificationResult:
    try:
        verification_mode = VerificationMode(mode)
    except ValueError:
        return VerificationResult((f"unsupported verification mode {mode!r}",), ())
    try:
        profile = parse_profile(profile_value)
    except SchemaError as error:
        return VerificationResult((f"profile.{error}",), ())
    try:
        report = parse_report(report_value)
    except SchemaError as error:
        return VerificationResult((f"report.{error}",), ())
    return evaluate(
        report,
        profile,
        mode=verification_mode,
        expected_app_version=expected_app_version,
        expected_app_build=expected_app_build,
    )
