// The admin app is built from the main app's own look: this copies the token layer (theme.dart),
// its additions (ui/tokens.dart) and the components (ui/kit.dart) into admin/lib unchanged.
// Edit the originals in app/lib, then run from the project root:
//   node tools/sync-admin-ui.mjs
// (The icons come from tools/gen-icons.mjs, which writes both apps' icon sets.)
import { readFileSync, writeFileSync } from 'node:fs';

const files = ['theme.dart', 'ui/tokens.dart', 'ui/kit.dart'];
for (const f of files) {
  const src = readFileSync(`app/lib/${f}`, 'utf8');
  writeFileSync(`admin/lib/${f}`, `// Copied from app/lib/${f} by tools/sync-admin-ui.mjs. Edit the original, not this copy.\n${src}`);
}
console.log(`admin/lib: ${files.join(', ')} copied from app/lib`);
