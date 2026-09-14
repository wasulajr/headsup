# Input is slurped: reject empty/multiple documents instead of emitting bad settings.
if length != 1 then error("expected one settings document") else .[0] end
| if type != "object" then error("settings must be an object") else . end
| if has("hooks") and (.hooks | type) != "object"
  then error("hooks must be an object") else . end
| .hooks = (.hooks // {})
| if any(.hooks[]; type != "array")
  then error("each hook event must be an array") else . end
| if any(.hooks[][]; type != "object")
  then error("each hook registration must be an object") else . end
# Append only missing complete registrations. Command-only dedup loses matchers,
# timeouts, and other meaningful metadata. Never reorder or dedup existing entries.
| reduce ($wiring | keys_unsorted[]) as $event (.;
    .hooks[$event] = (reduce $wiring[$event][] as $entry
      (.hooks[$event] // []; if index($entry) == null then . + [$entry] else . end)))
