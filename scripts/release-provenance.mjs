import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, lstatSync, readlinkSync } from 'node:fs';
import { join } from 'node:path';

/** Identifies the actual source snapshot, including uncommitted input, without copying private files. */
export function sourceProvenance(root) {
  const git = args => execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trimEnd();
  const paths = [...new Set(git(['ls-files', '-z', '--cached', '--others', '--exclude-standard']).split('\0').filter(Boolean))].sort();
  const files = [];
  for (const path of paths) {
    try {
      const stat = lstatSync(join(root, path));
      const bytes = stat.isSymbolicLink() ? readlinkSync(join(root, path)) : readFileSync(join(root, path));
      files.push({ path, sha256: createHash('sha256').update(bytes).digest('hex') });
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  return {
    commit: git(['rev-parse', 'HEAD']),
    dirty: git(['status', '--porcelain']).length > 0,
    sha256: createHash('sha256').update(JSON.stringify(files)).digest('hex'),
    files,
  };
}
