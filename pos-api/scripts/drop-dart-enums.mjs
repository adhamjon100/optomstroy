// scripts/gen_enums.py (RM-B-009) пишет enums.ts и enums.dart в один каталог; pos-api нужен только TS.
// Dart-версия — задача RM-C-004 (pos-app/lib/core/enums.dart).
import { rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

rmSync(fileURLToPath(new URL('../src/common/enums.dart', import.meta.url)), { force: true });
