import { describe, expect, it } from 'vitest';
import { detectBackground, joinArgv, shellText, splitArgv } from '../src/lib/argv';

describe('splitArgv', () => {
  it('splits on whitespace', () => {
    expect(splitArgv('  mvn   spring-boot:run ')).toEqual({ argv: ['mvn', 'spring-boot:run'], error: null });
  });

  it('honours single and double quotes', () => {
    expect(splitArgv(`node -e 'console.log("hi there")'`).argv).toEqual(['node', '-e', 'console.log("hi there")']);
    expect(splitArgv(`echo "a b" c`).argv).toEqual(['echo', 'a b', 'c']);
    expect(splitArgv(`run --name="my app"`).argv).toEqual(['run', '--name=my app']);
  });

  it('handles escapes inside and outside double quotes', () => {
    expect(splitArgv(`echo "say \\"hi\\" \\$HOME \\n"`).argv).toEqual(['echo', 'say "hi" $HOME \\n']);
    expect(splitArgv('path/with\\ space x').argv).toEqual(['path/with space', 'x']);
    expect(splitArgv(`'it'\\''s'`).argv).toEqual(["it's"]);
  });

  it('keeps empty quoted arguments', () => {
    expect(splitArgv(`cmd "" ''`).argv).toEqual(['cmd', '', '']);
  });

  it('does not expand or treat operators specially', () => {
    expect(splitArgv('pnpm dev &').argv).toEqual(['pnpm', 'dev', '&']);
    expect(splitArgv('echo $HOME *').argv).toEqual(['echo', '$HOME', '*']);
  });

  it('reports unterminated quotes', () => {
    expect(splitArgv(`echo "oops`).error).toBe('双引号未闭合');
    expect(splitArgv(`echo 'oops`).error).toBe('单引号未闭合');
  });

  it('round-trips through joinArgv', () => {
    const cases = [['a', 'b c', ''], ["it's", '"q"', '$x', 'tab\there'], ['./mvnw', '-Dspring-boot.run.profiles=dev']];
    for (const argv of cases) expect(splitArgv(joinArgv(argv)).argv).toEqual(argv);
  });
});

describe('shellText', () => {
  it('recognises shell wrappers', () => {
    expect(shellText(['/bin/zsh', '-lc', 'npm run dev && x'])).toEqual({ shell: '/bin/zsh', flag: '-lc', text: 'npm run dev && x' });
    expect(shellText(['bash', '-c', 'x'])?.text).toBe('x');
    expect(shellText(['node', '-c', 'x'])).toBeNull();
  });
});

describe('detectBackground', () => {
  it('flags a trailing or standalone &', () => {
    expect(detectBackground('pnpm dev &')).toBe('&');
    expect(detectBackground('pnpm dev&')).toBe('&');
    expect(detectBackground('a & b')).toBe('&');
  });
  it('ignores && and redirections', () => {
    expect(detectBackground('a && b')).toBeNull();
    expect(detectBackground('cmd 2>&1')).toBeNull();
    expect(detectBackground('cmd &> out.log')).toBeNull();
    expect(detectBackground(`echo "a & b"`)).toBeNull();
  });
  it('flags nohup / setsid and docker detach flags', () => {
    expect(detectBackground('nohup java -jar app.jar')).toBe('nohup');
    expect(detectBackground('cd x && nohup y')).toBe('nohup');
    expect(detectBackground('docker compose up -d')).toBe('-d');
    expect(detectBackground('docker run -itd nginx')).toBe('-d');
    expect(detectBackground('docker compose up')).toBeNull();
    expect(detectBackground('vite --host -d')).toBeNull();
  });
});
