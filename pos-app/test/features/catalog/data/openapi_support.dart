// Чтение contracts/openapi/pos-api.v1.yaml для тестов DTO каталога (ADR-085): свойства схем
// с объединением `allOf`, обязательные поля и синтетические примеры по схеме (значения
// `example` контракта, иначе — по типу/формату/шаблону). YAML читает Python + PyYAML,
// как в test/core/network/models/dto_schema_test.dart.
import 'dart:convert';
import 'dart:io';

const String _script = r'''
import json, sys, yaml
spec = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
S = spec["components"]["schemas"]

def name_of(ref):
    return ref.split("/")[-1]

def resolve(s):
    while "$ref" in s:
        s = S[name_of(s["$ref"])]
    return s

def flat(s):
    s = resolve(s)
    props, req = {}, set()
    for part in s.get("allOf", []):
        p, r = flat(part)
        props.update(p)
        req |= r
    props.update(s.get("properties", {}))
    req |= set(s.get("required", []))
    return props, req

def is_object(s):
    s = resolve(s)
    if "properties" in s or s.get("type") == "object":
        return True
    return any(is_object(p) for p in s.get("allOf", []))

def example(s, depth=0):
    if "$ref" in s:
        target = S[name_of(s["$ref"])]
        if "example" in target and not is_object(target):
            return target["example"]
        return example(target, depth)
    if "example" in s and not is_object(s):
        return s["example"]
    if "allOf" in s and not is_object(s):
        return example(s["allOf"][0], depth)
    if "anyOf" in s or "oneOf" in s:
        return example((s.get("anyOf") or s.get("oneOf"))[0], depth)
    if is_object(s) and ("properties" in s or "allOf" in s):
        props, _ = flat(s)
        return {k: example(v, depth + 1) for k, v in props.items()}
    if "enum" in s:
        return next(e for e in s["enum"] if e is not None)
    t = s.get("type")
    if t == "array":
        return [] if depth > 3 else [example(s["items"], depth + 1)]
    if t == "object":
        ap = s.get("additionalProperties")
        if isinstance(ap, dict):
            return {"color": example(ap, depth + 1)}
        return {}
    if t == "integer":
        return max(s.get("minimum", 1), 1) if s.get("maximum", 2) >= 1 else s.get("minimum", 0)
    if t == "number":
        return 1
    if t == "boolean":
        return True
    if t == "string":
        f, pat = s.get("format"), s.get("pattern", "")
        if f == "uuid":
            return "0192d1c3-7b8e-7c3f-9a10-3f5e2d1c0b9a"
        if f == "date-time":
            return "2026-10-19T09:00:00Z"
        if f == "date":
            return "2026-10-19"
        if pat == "^[0-9a-f]{64}$":
            return "a" * 64
        if "\\d{1,11}" in pat:
            return "124.000"
        if "\\d{1,12}" in pat:
            return "16007.50"
        if pat:
            return "ABC-123"
        return "текст"
    return None

def response_props(path, method="get", code="200"):
    schema = spec["paths"][path][method]["responses"][code]["content"]["application/json"]["schema"]
    props, req = flat(schema)
    return {"props": sorted(props), "required": sorted(req)}

names = sys.argv[2].split(",")
out = {"schemas": {}, "examples": {}, "responses": {}}
for n in names:
    props, req = flat({"$ref": "#/components/schemas/" + n})
    out["schemas"][n] = {"props": sorted(props), "required": sorted(req)}
    out["examples"][n] = example({"$ref": "#/components/schemas/" + n})
for p in ["/catalog/products", "/search/products", "/favorites/products", "/sync/runs", "/sync/runs/{id}/errors"]:
    out["responses"][p] = response_props(p)
out["entitySchemas"] = {k: name_of(v) for k, v in S["CatalogSyncResponse"].get("x-entity-schema", {}).items()}
json.dump(out, sys.stdout, ensure_ascii=False, default=str)
''';

/// Свойства, обязательные поля и примеры схем [names]; `null` — нет Python с PyYAML.
final class OpenApiFacts {
  OpenApiFacts._(this._data);

  final Map<String, Object?> _data;

  static OpenApiFacts? load(List<String> names) {
    for (final String python in <String>['python', 'python3', 'py']) {
      try {
        final ProcessResult r = Process.runSync(python, <String>[
          '-I',
          '-X',
          'utf8',
          '-c',
          _script,
          '../contracts/openapi/pos-api.v1.yaml',
          names.join(','),
        ], stdoutEncoding: utf8);
        if (r.exitCode == 0) return OpenApiFacts._(jsonDecode(r.stdout as String) as Map<String, Object?>);
      } on ProcessException {
        continue;
      }
    }
    return null;
  }

  Map<String, Object?> _schema(String name) =>
      (_data['schemas']! as Map<String, Object?>)[name]! as Map<String, Object?>;

  Set<String> props(String name) => (_schema(name)['props']! as List<Object?>).cast<String>().toSet();

  Set<String> required(String name) => (_schema(name)['required']! as List<Object?>).cast<String>().toSet();

  /// Синтетический пример схемы (JSON-объект).
  Map<String, dynamic> example(String name) =>
      ((_data['examples']! as Map<String, Object?>)[name]! as Map<String, Object?>).cast<String, dynamic>();

  /// `CatalogSyncResponse.x-entity-schema`: сущность выгрузки → имя схемы элемента `items`.
  Map<String, String> entitySchemas() =>
      ((_data['entitySchemas'] as Map<String, Object?>?) ?? const <String, Object?>{}).cast<String, String>();

  Set<String> responseProps(String path) {
    final responses = _data['responses']! as Map<String, Object?>;
    final response = responses[path]! as Map<String, Object?>;
    return (response['props']! as List<Object?>).cast<String>().toSet();
  }
}
