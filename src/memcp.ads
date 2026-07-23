--  memcp: the composition root's namespace. Holds no declarations of its own
--  -- it exists only so Env, Json, Envelope, Extractor, Log, Replay,
--  Resources, Store, Text, and Tools can be its children.
package Memcp with SPARK_Mode => On is
end Memcp;
