/** Free (no-LLM) LexDigestGlobal relevance scorer — mirror of Edge Function. */

const RULES = [
  {
    criteria: "EU Regulation",
    weight: 0.35,
    patterns: [
      /\beu\b/i,
      /\beuropean (union|commission|parliament|council)\b/i,
      /\bcelex\b/i,
      /\bofficial journal\b/i,
      /\bregulation\b/i,
      /\bdirective\b/i,
      /\btrilogue\b/i,
      /\bdue diligence\b/i,
      /\bcsrd\b|\bcsddd\b|\bgdpr\b|\bai act\b|\bdma\b|\bdsa\b/i,
      /\bbrussels\b/i,
      /\beu[- ]law\b/i,
    ],
  },
  {
    criteria: "Sanctions",
    weight: 0.4,
    patterns: [
      /\bsanction/i,
      /\bembargo\b/i,
      /\bexport control/i,
      /\basset freez/i,
      /\bofac\b|\bofsi\b/i,
      /\brestrictive measure/i,
      /\bblacklist(ed|ing)?\b/i,
      /\bsecondary sanction/i,
    ],
  },
  {
    criteria: "Defence Supply Chains",
    weight: 0.4,
    patterns: [
      /\bdefen[cs]e\b/i,
      /\bmilitary\b/i,
      /\bnato\b/i,
      /\barms?\b|\bweapon/i,
      /\bmunition/i,
      /\bsupply chain/i,
      /\bprocurement\b/i,
      /\baerospace\b/i,
      /\bmissile\b|\bdrone\b|\buav\b/i,
      /\bammunition\b/i,
      /\bdefence industr/i,
    ],
  },
  {
    criteria: "Geopolitics",
    weight: 0.3,
    patterns: [
      /\bgeopolitic/i,
      /\bukraine\b|\brussia\b|\bchina\b|\btaiwan\b|\biran\b|\bisrael\b|\bgaza\b/i,
      /\bmiddle east\b/i,
      /\bsecurity policy\b/i,
      /\bforeign policy\b/i,
      /\bdiplomacy\b|\bsummit\b/i,
      /\bnuclear\b/i,
      /\binvasion\b|\bceasefire\b/i,
      /\bhybrid (war|threat)/i,
    ],
  },
]

export const QUEUE_THRESHOLD = 0.35

export function scoreKeywords({ title, snippet, sourceName = "" }) {
  const text = `${title}\n${snippet}\n${sourceName}`
  const criteria = new Set()
  const matched = []
  let score = 0

  for (const rule of RULES) {
    let hit = false
    for (const re of rule.patterns) {
      const m = text.match(re)
      if (m) {
        hit = true
        matched.push(m[0].toLowerCase())
      }
    }
    if (hit) {
      criteria.add(rule.criteria)
      score += rule.weight
    }
  }

  if (criteria.size >= 2) score += 0.1
  if (criteria.size >= 3) score += 0.1

  score = Math.min(1, Math.round(score * 1000) / 1000)
  const relevant = score >= QUEUE_THRESHOLD && criteria.size > 0
  const uniq = [...new Set(matched)].slice(0, 12)

  return {
    relevant,
    score,
    reason: relevant
      ? `keyword match: ${[...criteria].join(", ")} (${uniq.join(", ")})`
      : uniq.length
        ? `below threshold (${score}): ${uniq.join(", ")}`
        : "no strategic keywords",
    criteria: [...criteria],
    matched: uniq,
  }
}
