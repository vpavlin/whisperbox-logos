# ADR 0013 — Private replies and quiz scores via a per-answer reply key

Status: accepted (0.3.8 desktop / 0.3.9 Android). Recorded 2026-10-03.

## Context
Creators want to reply to one respondent and to grade quizzes, without learning who the
respondent is (anonymous forms) and without anyone else reading the reply.

## Decision
- Every answer carries `replyPub`, the public half of
  `HKDF(identityPriv, "whisperbox-reply-v1", lc(formId) + "|" + confirmationId)`: re-derivable
  by the respondent (nothing to store), unlinkable by others.
- `response.reply {to: confirmationId, sealed}` (creator or co-owner, signed) seals
  `{message}` or `{kind: "score", score, outOf, correct}` to that key.
- Quiz: the right answers (`{qid: {answer, points}}`) are sealed to the form key as
  `quizKey`, so only the creator and co-owners can read them. Scores are computed locally
  with the shared rules in `contract/answers.mjs` (C++ mirror, pinned by
  `answer-validation.json`). "Send scores" sends one score reply to each answer that has no
  reply yet.
- Respondents see replies and scores only for their own answer; the phone notifies.

## Consequences
- Public: that a reply was sent to some receipt id, and by whom.
- Answers from apps older than 0.3.8 carry no reply key and can't be replied to.
- Text answers match accepted spellings after trim, case and whitespace folding; anything
  fuzzier needs a manual reply.
