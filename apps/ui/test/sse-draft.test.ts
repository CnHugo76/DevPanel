import { describe, expect, it } from 'vitest';
import type { ProjectConfig } from '@devpanel/contract';
import { SseParser } from '../src/api/sse';
import { buildConfig, draftFromConfig, parseConfigJson, secretValuesOf, slugify, storedSecretsOf } from '../src/lib/draft';

describe('SseParser', () => {
  it('parses events across arbitrary chunk boundaries', () => {
    const got: Array<[string, string]> = [];
    const p = new SseParser((e, d) => got.push([e, d]));
    const stream = 'event: snapshot\ndata: {"a":1}\n\n: comment\n\nevent: ping\r\ndata: {"b":\r\ndata: 2}\r\n\r\ndata: plain\n\n';
    for (const ch of stream) p.feed(ch);
    expect(got).toEqual([
      ['snapshot', '{"a":1}'],
      ['ping', '{"b":\n2}'],
      ['message', 'plain'],
    ]);
  });

  it('waits for a complete line when a chunk ends with \\r', () => {
    const got: string[] = [];
    const p = new SseParser((_e, d) => got.push(d));
    p.feed('data: x\r');
    p.feed('\n\r');
    p.feed('\n');
    expect(got).toEqual(['x']);
  });

  it('discards an unterminated event at end of stream', () => {
    const got: string[] = [];
    const p = new SseParser((_e, d) => got.push(d));
    p.feed('data: partial');
    p.end();
    expect(got).toEqual([]);
  });
});

const saved: ProjectConfig = {
  schemaVersion: 1,
  name: 'order-service',
  root: '/Users/h/Project/order-service',
  env: { LANG: 'en_US.UTF-8' },
  services: [
    {
      id: 'backend',
      name: '后端',
      cwd: 'backend',
      command: ['./mvnw', 'spring-boot:run', '-Dspring-boot.run.profiles=dev'],
      env: { JAVA_HOME: '/opt/jdk', DB_PASSWORD: { secret: true } },
      stopTimeoutSec: 10,
    },
    { id: 'frontend', name: '前端', cwd: 'frontend', command: ['/bin/zsh', '-lc', 'pnpm install && pnpm dev'] },
  ],
};

describe('config draft', () => {
  it('round-trips a saved config losslessly', () => {
    const d = draftFromConfig(saved, { stored: storedSecretsOf(saved), savedIds: ['backend', 'frontend'] });
    expect(d.services[1]!.viaShell).toBe(true);
    expect(d.services[1]!.commandText).toBe('pnpm install && pnpm dev');
    const { config, errors } = buildConfig(d, 'save');
    expect(errors).toEqual({});
    expect(config).toEqual(saved); // stored secret stays as the keep marker
  });

  it('sends new secret values on save but never shows them in JSON', () => {
    const d = draftFromConfig(saved, { stored: storedSecretsOf(saved) });
    d.services[0]!.env[1]!.value = 'new-pass';
    expect(buildConfig(d, 'save').config.services[0]!.env!.DB_PASSWORD).toEqual({ secret: true, value: 'new-pass' });
    const json = buildConfig(d, 'json').config;
    expect(JSON.stringify(json)).not.toContain('new-pass');
    // JSON → form keeps the typed value through secretValues
    const back = draftFromConfig(json, { secretValues: secretValuesOf(d), stored: storedSecretsOf(saved) });
    expect(back.services[0]!.env[1]!.value).toBe('new-pass');
  });

  it('requires a value for a new secret', () => {
    const d = draftFromConfig({ ...saved, services: [{ ...saved.services[0]!, env: { API_TOKEN: { secret: true } } }] });
    expect(buildConfig(d, 'save').errors['services[0].env.API_TOKEN']).toBeTruthy();
  });

  it('reports argv parse errors and invalid stop timeouts', () => {
    const d = draftFromConfig(saved);
    d.services[0]!.commandText = 'echo "unterminated';
    d.services[0]!.stopTimeoutSec = '0';
    const { errors } = buildConfig(d, 'save');
    expect(errors['services[0].command']).toBe('双引号未闭合');
    expect(errors['services[0].stopTimeoutSec']).toBeTruthy();
  });

  it('slugifies service names into unique IDs', () => {
    expect(slugify('后端', [])).toBe('backend');
    expect(slugify('Web Admin!', [])).toBe('web-admin');
    expect(slugify('前端', ['frontend'])).toBe('frontend-2');
    expect(slugify('服务 2', [])).toBe('service-2');
    expect(slugify('123', [])).toBe('service');
  });

  it('parses JSON with error positions', () => {
    const bad = parseConfigJson('{\n  "name": "x",\n  oops\n}');
    expect(bad.config).toBeNull();
    expect(bad.line).toBe(3);
    expect(parseConfigJson('[]').error).toBe('顶层必须是对象');
    expect(parseConfigJson('{"services": [{"command": "npm run dev"}]}').error).toContain('argv');
    expect(parseConfigJson(JSON.stringify(saved)).config).toEqual(saved);
  });
});
