#!/usr/bin/env node
/**
 * build-projects.js — generate projects.json for LexCockpit from your website repo.
 *
 * Reads content/articles/*.md (YAML front-matter) and writes a projects.json the
 * Mac app can open. Dependency-free — run it from inside your lexdigestglobal repo:
 *
 *     node path/to/build-projects.js > projects.json
 *
 * Then in LexCockpit: Projects → "Open projects.json…" and pick that file.
 */
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = process.cwd();
const DIR = path.join(ROOT, 'content', 'articles');
const BASE = 'https://lexdigestglobal.com/articles/';

// Site workspace config for the LexCockpit tabs (Overview · Content · CMS ·
// Deploys · Repo). NO SECRETS here — tokens live in the macOS Keychain.
// netlify_site_id: Netlify → Site configuration → General → Site ID.
const SITES = [
  {
    id: 'lexdigestglobal',
    name: 'LexDigestGlobal',
    url: 'https://lexdigestglobal.com',
    cms_url: 'https://lexdigestglobal.com/admin/',
    repo: 'tg-netizen/lexdigestglobal-real-version',
    default_branch: 'main',
    netlify_site_id: '',
    content_paths: ['content/articles/'],
  },
];

// Minimal front-matter reader: top-level `key: value` lines + simple `- item` lists.
function frontmatter(raw) {
  if (!raw.startsWith('---')) return {};
  const end = raw.indexOf('\n---', 3);
  if (end === -1) return {};
  const lines = raw.slice(3, end).split('\n');
  const data = {};
  let listKey = null;
  for (const line of lines) {
    const listItem = line.match(/^\s*-\s+(.*)$/);
    if (listItem && listKey) { data[listKey].push(unquote(listItem[1])); continue; }
    const kv = line.match(/^([A-Za-z0-9_]+):\s*(.*)$/);
    if (!kv) continue;
    const key = kv[1];
    const val = kv[2].trim();
    if (val === '') { listKey = key; data[key] = []; }        // start of a block list
    else { listKey = null; data[key] = unquote(val); }
  }
  return data;
}
function unquote(s) { return s.replace(/^['"]|['"]$/g, '').trim(); }

if (!fs.existsSync(DIR)) { console.error('No content/articles/ here — run from the website repo root.'); process.exit(1); }

const projects = fs.readdirSync(DIR)
  .filter(f => f.endsWith('.md'))
  .map(f => {
    const slug = f.replace(/\.md$/, '');
    const fm = frontmatter(fs.readFileSync(path.join(DIR, f), 'utf8'));
    const status = fm.status || 'draft';
    return {
      id: slug,
      title: fm.title || slug,
      type: fm.type || 'article',
      status,
      date: fm.date || '',
      scheduledPublishAt: fm.scheduled_publish_at || '',
      topic: Array.isArray(fm.topics) ? (fm.topics[0] || '') : (fm.topic || ''),
      url: status === 'published' ? BASE + slug + '.html' : ''
    };
  })
  .sort((a, b) => String(b.date).localeCompare(String(a.date)));

process.stdout.write(JSON.stringify({ sites: SITES, projects }, null, 2) + '\n');
console.error(`Wrote ${projects.length} projects + ${SITES.length} site workspace(s).`);
