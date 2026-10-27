import assert from "node:assert/strict";

export function runSettings(optimize, env = process.env) {
  assert(["Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"].includes(optimize), "pass the compiler optimization mode after the ss binary");
  const record = env.SS_PROFILE_RECORD ?? "1";
  assert(record === "0" || record === "1", "SS_PROFILE_RECORD must be 0 or 1");
  return {
    optimize,
    record: record === "1",
    samples: integer(env, "SS_PROFILE_SAMPLES", 3, 1, 1000),
    warmups: integer(env, "SS_PROFILE_WARMUPS", 1, 0, 1000),
    timeout_ms: integer(env, "SS_PROFILE_TIMEOUT_MS", 180_000, 1, 3_600_000),
    script_timeout_ms: integer(env, "SS_PROFILE_SCRIPT_TIMEOUT_MS", 1_800_000, 1, 86_400_000),
    profile_buffer_kb: integer(env, "SS_PROFILE_BUFFER_KB", 32768, 64, 1_048_576),
    cache_scope: "owned project .ss-cache only; OS/font/tool caches are not cleared",
    detailed_recordings_separate: true,
  };
}

function integer(env, name, fallback, minimum, maximum) {
  const value = env[name] ?? String(fallback);
  const number = Number(value);
  assert(/^\d+$/.test(value) && Number.isSafeInteger(number) && number >= minimum && number <= maximum, `${name} must be an integer between ${minimum} and ${maximum}`);
  return number;
}
