/**
 * Side-channel fetcher: the Singapore public-sector Workable accounts.
 *
 * Why this exists
 * ---------------
 * `scripts/fetch-jobs.ts` reads the Careers@Gov OData feed (SAP SuccessFactors
 * requisitions) plus two hand-listed ATS boards. Workable-hosted postings are
 * not in that feed, so any agency publishing to its own Workable account is
 * invisible unless it is listed there by name. Rather than depend on a fork of
 * upstream's fetcher (and a set of secrets this fork does not have), this
 * script fetches just the Workable accounts into its own data file.
 *
 * The output file is written only by this script and by no upstream commit, so
 * the fork's data can stay in lock-step with upstream without the two ever
 * fighting over `data/job-listings.json`.
 *
 * Usage
 * -----
 *   deno run --allow-import --allow-net --allow-read --allow-write \
 *     scripts/fetch-workable.ts [output.json]
 *
 * Defaults to `data/workable-job-listings.json`; also writes a sibling `.csv`.
 * Output is sorted (account, then shortcode) so an unchanged board produces a
 * byte-identical file and no commit.
 *
 * The processing helpers are imported from `fetch-jobs.ts` on purpose: the
 * flattened row shape must stay identical to the main data file, and a second
 * copy of that logic would drift.
 */

import { stringify } from 'https://deno.land/std@0.218.0/csv/stringify.ts'
import { writeJSON } from 'https://deno.land/x/flat@0.0.15/mod.ts'
import {
  fetchWorkableAccount,
  fetchWorkableJobDetail,
  processWorkableJob,
  WORKABLE_ACCOUNTS,
} from './fetch-jobs.ts'
import type { ProcessedJob } from './fetch-jobs.ts'

const DEFAULT_OUT = 'data/workable-job-listings.json'

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function main() {
  const outputFilename = Deno.args[0] ?? DEFAULT_OUT
  const processedJobs: ProcessedJob[] = []
  let accountsFound = 0

  for (const [acctIndex, account] of WORKABLE_ACCOUNTS.entries()) {
    if (acctIndex > 0) {
      // One listings call per account; space them out to stay clear of
      // Workable's per-IP rate limiting on the public API.
      await sleep(1000)
    }

    const accountData = await fetchWorkableAccount(account)
    if (accountData === null) continue // account no longer exists; already warned

    accountsFound++
    const agency = accountData.name ?? ''
    const agencyDescription = accountData.description ?? ''
    const summaries = accountData.jobs ?? []
    console.log(`  Fetching ${summaries.length} Workable job details for ${account}...`)

    for (const [i, summary] of summaries.entries()) {
      const detail = await fetchWorkableJobDetail(account, summary.shortcode)
      processedJobs.push(processWorkableJob(summary, detail, account, agency, agencyDescription))
      if (i < summaries.length - 1) {
        await sleep(100)
      }
    }

    console.log(`✅ Processed ${summaries.length} Workable jobs from ${account}`)
  }

  // Stable order: account, then posting shortcode.
  processedJobs.sort((a, b) =>
    a.jobId === b.jobId
      ? (a.postingNo < b.postingNo ? -1 : a.postingNo > b.postingNo ? 1 : 0)
      : (a.jobId < b.jobId ? -1 : 1)
  )

  await writeJSON(outputFilename, processedJobs, null, 2)

  const csvFilename = outputFilename.replace(/\.json$/, '.csv')
  const csv = stringify(processedJobs, { columns: Object.keys(processedJobs[0] ?? {}) })
  await Deno.writeTextFile(csvFilename, csv)

  console.log(`✅ ${processedJobs.length} Workable jobs from ${accountsFound} accounts`)
  console.log(`✅ Saved: ${outputFilename} and ${csvFilename}`)
}

if (import.meta.main) {
  main().catch((error) => {
    console.error('❌ Error processing Workable accounts:', error)
    Deno.exit(1)
  })
}
