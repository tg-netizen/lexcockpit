#!/usr/bin/env node
import { scoreKeywords, QUEUE_THRESHOLD } from "./lib/keywords.mjs"

let ok = true
function expect(cond, name) {
  console.log(cond ? `PASS  ${name}` : `FAIL  ${name}`)
  if (!cond) ok = false
}

const hit = scoreKeywords({
  title: "EU Council adopts new Russia sanctions package",
  snippet: "Restrictive measures target defence supply chains and dual-use exports.",
  sourceName: "Politico Europe",
})
expect(hit.relevant === true, "sanctions + EU story is queued")
expect(hit.score >= QUEUE_THRESHOLD, "score meets threshold")
expect(hit.criteria.includes("Sanctions"), "detects Sanctions")
expect(hit.criteria.includes("EU Regulation") || hit.criteria.includes("Defence Supply Chains"),
  "detects EU or Defence axis")

const miss = scoreKeywords({
  title: "Local football club wins friendly match",
  snippet: "Fans celebrated into the night after a 2-1 victory.",
  sourceName: "ABC News World",
})
expect(miss.relevant === false, "sports story is rejected")
expect(miss.score < QUEUE_THRESHOLD, "sports score below threshold")

process.exit(ok ? 0 : 1)
