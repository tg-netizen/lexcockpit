/**
 * Free (no-LLM) LexDigestGlobal relevance scorer.
 * Keyword / phrase heuristics for EU regulation, sanctions, defence, geopolitics.
 */

export interface KeywordVerdict {
  relevant: boolean
  score: number
  reason: string
  criteria: string[]
  matched: string[]
}

type Rule = {
  criteria: string
  weight: number
  patterns: RegExp[]
}

const RULES: Rule[] = [
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
      /\bammunication\b|\bammunition\b/i,
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

/** Minimum score to land on the human review waiting list. */
export const QUEUE_THRESHOLD = 0.35

export function scoreKeywords(input: {
  title: string
  snippet: string
  sourceName?: string
}): KeywordVerdict {
  const text = `${input.title}\n${input.snippet}\n${input.sourceName ?? ""}`
  const criteria = new Set<string>()
  const matched: string[] = []
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

  // Slight boost when multiple strategic axes match.
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
