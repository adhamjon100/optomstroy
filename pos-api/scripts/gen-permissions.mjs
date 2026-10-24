#!/usr/bin/env node
// RM-C-005: генератор src/common/rbac/permissions.generated.ts из contracts/rbac/permissions.yaml (RM-B-008).
// Зачем генерация, а не чтение YAML при старте: образ pos-api не содержит contracts/, а новые переменные
// окружения (путь к файлу) вне 16 §4.3 запрещены (RM-C-009 п. 3). Сверка — `npm run check:permissions`
// и unit-тест src/common/rbac/permissions.generated.spec.ts.
//
// Запуск: node scripts/gen-permissions.mjs [--check] [--input <permissions.yaml>]
// Код выхода: 0 — успех / актуально; 1 — файл устарел (--check) или ошибка входных данных.
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';

const args = process.argv.slice(2);
const check = args.includes('--check');
const inputIdx = args.indexOf('--input');
const input =
  inputIdx >= 0 ? args[inputIdx + 1] : fileURLToPath(new URL('../../contracts/rbac/permissions.yaml', import.meta.url));
const output = fileURLToPath(new URL('../src/common/rbac/permissions.generated.ts', import.meta.url));

const raw = readFileSync(input, 'utf8');
const doc = parse(raw);
const sha = createHash('sha256').update(raw.replace(/\r\n/g, '\n'), 'utf8').digest('hex');

const errors = [];
const roles = (doc.roles ?? []).map((r) => r.code);
const codes = new Set();
const permissions = (doc.permissions ?? []).map((p) => {
  if (codes.has(p.code)) errors.push(`повтор кода ${p.code}`);
  codes.add(p.code);
  return {
    code: p.code,
    number: String(p.number),
    module: String(p.module),
    stepUp: Boolean(p.step_up),
    stepUpScope: p.step_up_scope ?? null,
    reserved: Boolean(p.reserved),
  };
});
const grants = {};
for (const role of roles) {
  const list = doc.grants?.[role] ?? [];
  for (const c of list) if (!codes.has(c)) errors.push(`grants.${role}: неизвестный код ${c}`);
  grants[role] = list;
}
for (const role of Object.keys(doc.grants ?? {})) if (!roles.includes(role)) errors.push(`grants: неизвестная роль ${role}`);
const constraints = {};
for (const role of roles) constraints[role] = doc.constraints?.[role] ?? {};
const pseudoSets = doc.pseudo_sets ?? {};
if (errors.length) {
  console.error(`gen-permissions: ошибки входных данных:\n  ${errors.join('\n  ')}`);
  process.exit(1);
}

const j = (v) => JSON.stringify(v);
const lines = [];
lines.push('// GENERATED FILE — DO NOT EDIT.');
lines.push(`// Source: contracts/rbac/permissions.yaml (version ${doc.version}, sha256 ${sha})`);
lines.push('// Generator: pos-api/scripts/gen-permissions.mjs (RM-C-005). Канон: 11 §4.3–§4.4, ядро R0 §18.1.');
lines.push('/* eslint-disable */');
lines.push('');
lines.push(`export const PERMISSIONS_SOURCE_SHA256 = '${sha}' as const;`);
lines.push(`export const PERMISSIONS_VERSION = ${Number(doc.version)} as const;`);
lines.push('');
lines.push(`export const RBAC_ROLES = ${j(roles)} as const;`);
lines.push('export type RbacRole = (typeof RBAC_ROLES)[number];');
lines.push('');
lines.push('export const PERMISSION_CODES = [');
for (const p of permissions) lines.push(`  ${j(p.code)},`);
lines.push('] as const;');
lines.push('export type PermissionCode = (typeof PERMISSION_CODES)[number];');
lines.push('');
lines.push('export interface PermissionMeta {');
lines.push('  readonly code: PermissionCode;');
lines.push('  readonly number: string;');
lines.push('  readonly module: string;');
lines.push('  readonly stepUp: boolean;');
lines.push('  readonly stepUpScope: string | null;');
lines.push('  readonly reserved: boolean;');
lines.push('}');
lines.push('');
lines.push('export const PERMISSIONS: readonly PermissionMeta[] = [');
for (const p of permissions) lines.push(`  ${j(p)},`);
lines.push('];');
lines.push('');
lines.push('/** Роль → выданные коды (deny by default: кода нет в списке — права нет). */');
lines.push('export const ROLE_GRANTS: { readonly [R in RbacRole]: readonly PermissionCode[] } = {');
for (const role of roles) lines.push(`  ${role}: ${j(grants[role])},`);
lines.push('};');
lines.push('');
lines.push('/** Атрибутные ограничители ячеек матрицы (role_permissions.constraint_json, 07 §5.6). */');
lines.push(
  'export const ROLE_CONSTRAINTS: { readonly [R in RbacRole]: Readonly<Partial<Record<PermissionCode, Readonly<Record<string, unknown>>>>> } = {',
);
for (const role of roles) lines.push(`  ${role}: ${j(constraints[role])},`);
lines.push('};');
lines.push('');
lines.push('/** Псевдо-наборы guard (не роли): например, статус pending_activation (11 §4.2). */');
lines.push('export const PSEUDO_SETS: Readonly<Record<string, readonly PermissionCode[]>> = {');
for (const [k, v] of Object.entries(pseudoSets)) lines.push(`  ${k}: ${j(v)},`);
lines.push('};');
lines.push('');
const text = lines.join('\n');

if (check) {
  const current = existsSync(output) ? readFileSync(output, 'utf8').replace(/\r\n/g, '\n') : '';
  if (current !== text) {
    console.error('gen-permissions: permissions.generated.ts устарел — выполните `npm run gen:permissions`');
    process.exit(1);
  }
  console.log(`gen-permissions: актуально (${permissions.length} кодов, ${roles.length} ролей)`);
} else {
  writeFileSync(output, text, 'utf8');
  console.log(`gen-permissions: ${permissions.length} кодов, ${roles.length} ролей → ${output}`);
}
