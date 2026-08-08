/**
 * GENERATED from supabase/functions/_shared/keywords.ts — do not edit by hand.
 * Free (no-LLM) LexDigestGlobal relevance scorer.
 * Keyword / phrase heuristics for EU regulation, sanctions, defence, geopolitics.
 *
 * WHY TWO TIERS OF PATTERN
 * The first version scored every pattern equally, and generic words did the
 * damage: "New banking regulation tightens US mortgage lending" matched
 * `regulation` and landed on the waiting list at exactly the threshold, as did
 * "Hospital procurement reform saves millions". Measured against live feeds,
 * 35% of everything fetched was being queued.
 *
 *   `strong` — evidence of the axis on its own. "sanctions", "CELEX", "NATO".
 *   `weak`   — consistent with the axis but common elsewhere. "regulation",
 *              "procurement", "summit", "EU".
 *
 * A rule fires when it has one strong hit, OR two weak hits (evidence
 * accumulating inside one axis: "EU" + "regulation" together mean something
 * that "regulation" alone does not), OR one weak hit while another axis fired
 * strong. Nothing qualifies on a single generic word any more.
 *
 * WHY THE SOURCE NAME IS NOT SCORED
 * It used to be concatenated into the scored text, which meant the feed's own
 * title voted on every item it carried. "Defence News" matches the defence
 * rule, so 20 of 20 live items from that source were queued regardless of
 * content — an article about a pop album scored 0.40 from the source name
 * alone, and 0.85 from "EU Sanctions Map News". The source is metadata, not
 * evidence about the article.
 */

const RULES = [
  {
    criteria: "EU Regulation",
    weight: 0.35,
    strong: [
      /\beuropean (union|commission|parliament|council)\b/i,
      /\bcelex\b/i,
      /\bofficial journal\b/i,
      /\btrilogue\b/i,
      /\bcsrd\b|\bcsddd\b|\bgdpr\b|\bai act\b|\bdma\b|\bdsa\b|\bcbam\b/i,
      /\beu[- ]law\b/i,
      /\beu (regulation|directive|rules?|sanctions?|law)\b/i,
      /\bcomitology\b|\bdelegated act\b|\bimplementing act\b/i,
      /* German — the seeded Tagesschau/Euractiv-DE/Bundesregierung feeds were
         being scored with English-only patterns and scored 0.00 on stories
         that would have scored 0.90 in English. */
      /\beu[- ]verordnung\b|\beu[- ]richtlinie\b/i,
      /\beurop(äische|äisches) (kommission|parlament|union|rat)\b/i,
      /\bamtsblatt\b/i,
      /\blieferkettengesetz\b|\blksg\b/i,
    ],
    weak: [
      /\beu\b/i,
      /\bregulation\b/i,
      /\bdirective\b/i,
      /\bdue diligence\b/i,
      /\bbrussels\b/i,
      /\bverordnung\b|\brichtlinie\b|\bbrüssel\b|\bgesetzentwurf\b/i,
    ],
  },
  {
    criteria: "Sanctions",
    weight: 0.4,
    strong: [
      /\bsanction/i,
      /\bembargo\b/i,
      /\bexport control/i,
      /\basset freez/i,
      /\bofac\b|\bofsi\b/i,
      /\brestrictive measure/i,
      /\bsecondary sanction/i,
      /\bdual[- ]use\b/i,
      /* German */
      /\bsanktion/i,
      /\bausfuhr(verbot|kontroll|beschränkung)/i,
      /\bhandelsbeschränkung/i,
      /\beinfuhrverbot\b/i,
      /\bvermögenswerte eingefroren\b|\bkontensperr/i,
    ],
    weak: [
      /\bblacklist(ed|ing)?\b/i,
      /\bfrozen assets?\b/i,
      /\bsperrliste\b/i,
    ],
  },
  {
    criteria: "Defence Supply Chains",
    weight: 0.4,
    strong: [
      /\bdefen[cs]e industr/i,
      /\bnato\b/i,
      /\bmunition/i,
      /\bammunition\b/i,
      /\bmissile\b|\bdrone\b|\buav\b/i,
      /\bweapons?\b|\barms (deal|export|delivery|package|industry|control)\b/i,
      /\bdefence procurement\b|\bdefense procurement\b/i,
      /\bmilitary (aid|supply|supplies|contract|procurement)\b/i,
      /\bshipyard\b|\bfrigate\b|\bsubmarine\b/i,
      /* German */
      /\brüstung(s|sindustrie|sgüter|skonzern|sunternehmen)?\b/i,
      /\bwaffen(lieferung|system|export)?\b/i,
      /\bbundeswehr\b|\bbaainbw\b/i,
      /\bverteidigungs(industrie|ministerium|etat|haushalt|ausgaben)\b/i,
      /\bwehrtechnik/i,
    ],
    weak: [
      /\bdefen[cs]e\b/i,
      /\bmilitary\b/i,
      /\bsupply chain/i,
      /\bprocurement\b/i,
      /\baerospace\b/i,
      /\blieferkette/i,
      /\bbeschaffung/i,
      /\bverteidigung\b/i,
    ],
  },
  {
    criteria: "Geopolitics",
    weight: 0.3,
    strong: [
      /\bgeopolitic/i,
      /\bgeopolitisch/i,
      /\bhybrid (war|threat)/i,
      /\bhybride (kriegsführung|bedrohung)/i,
      /\binvasion\b|\bceasefire\b|\bwaffenstillstand\b/i,
      /\bforeign policy\b|\baußenpolitik\b/i,
      /\bsecurity policy\b|\bsicherheitspolitik\b/i,
    ],
    weak: [
      /\bukraine\b|\brussia\b|\brussland\b|\bchina\b|\btaiwan\b|\biran\b|\bisrael\b|\bgaza\b/i,
      /\bmiddle east\b|\bnaher osten\b/i,
      /\bdiplomacy\b|\bsummit\b|\bgipfel\b|\bdiplomatie\b/i,
      /\bnuclear\b|\batomprogramm\b/i,
    ],
  },
]

/** Minimum score to land on the human review waiting list. */
export const QUEUE_THRESHOLD = 0.35

/**
 * Extra weight when one axis is densely represented. Without it, a rule can
 * never exceed its own weight, and Geopolitics — weight 0.3 against a 0.35
 * threshold — could not qualify on its own no matter how much geopolitical
 * vocabulary a headline contained. "Russia and China hold summit on Taiwan,
 * discussing the invasion and a possible ceasefire" scored 0.30 and was
 * dropped, while a single generic "regulation" got in at 0.35.
 *
 * Density counts strong AND weak hits, because several of the strong patterns
 * are alternations: every country sits in one regex, so three countries in a
 * headline register as a single hit. Counting only strong patterns left that
 * ceasefire headline one short of the bonus and it was still being dropped.
 * The bonus only ever applies to a rule that already fired, so a lone generic
 * word still cannot buy its way in.
 */
const DENSITY_BONUS = 0.1
const DENSITY_AT = 3

export function scoreKeywords(input) {
  /* sourceName is deliberately NOT scored — see the header. */
  const text = `${input.title}\n${input.snippet}`
  const matched = []

  const hits = RULES.map((rule) => {
    const strong = []
    const weak = []
    for (const re of rule.strong) {
      const m = text.match(re)
      if (m) strong.push(m[0].toLowerCase())
    }
    for (const re of rule.weak) {
      const m = text.match(re)
      if (m) weak.push(m[0].toLowerCase())
    }
    return { rule, strong, weak }
  })

  const anyStrong = hits.some((h) => h.strong.length > 0)

  const criteria = []
  let score = 0
  for (const h of hits) {
    const fires =
      h.strong.length > 0 ||
      h.weak.length >= 2 ||
      (h.weak.length >= 1 && anyStrong)
    if (!fires) continue
    criteria.push(h.rule.criteria)
    score += h.rule.weight
    if (h.strong.length + h.weak.length >= DENSITY_AT) score += DENSITY_BONUS
    matched.push(...h.strong, ...h.weak)
  }

  // Slight boost when multiple strategic axes match.
  if (criteria.length >= 2) score += 0.1
  if (criteria.length >= 3) score += 0.1

  score = Math.min(1, Math.round(score * 1000) / 1000)
  const relevant = score >= QUEUE_THRESHOLD && criteria.length > 0
  const uniq = [...new Set(matched)].slice(0, 12)

  return {
    relevant,
    score,
    reason: relevant
      ? `keyword match: ${criteria.join(", ")} (${uniq.join(", ")})`
      : uniq.length
        ? `below threshold (${score}): ${uniq.join(", ")}`
        : "no strategic keywords",
    criteria,
    matched: uniq,
  }
}
