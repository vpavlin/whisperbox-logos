# 0022 - Several answers per respondent

Status: accepted, 2026-11-11

## Context

A form took one answer per person, optionally editable for a while. Václav wants WhisperBox as the
Basecamp feedback channel, where one person sends many pieces of feedback, bug reports or feature
requests over time, and may be rewarded for them. That needs several answers from one identity.

## Decision

1. **A form setting, honoured by the respondent.** `maxPerRespondent`: 1 (the default, omitted), N, or
   0 for no limit. It is an editable field like `maxResponses`.
2. **Each answer is keyed by its receipt id.** Every answer already seals a random `confirmationId`.
   On these forms the creator view keys answers by (respondent, confirmationId). A repeat of a seen id
   is a copy (`duplicate-answer`). The respondent's cap is checked first (`over-respondent-limit`),
   then the form's `maxResponses`, which counts answers, not people. Accepted answers carry
   `answerNo` (1, 2, ... per respondent). The sealed answer format is unchanged.
3. **Signed only.** An unsigned answer is dropped (`sig-invalid`), as on edit-enabled and members-only
   forms; otherwise anyone could spend someone's quota or claim their rewards. An answer with no
   receipt id is dropped (`no-answer-id`).
4. **No edits.** Writers refuse `allowEdits` together with `maxPerRespondent != 1`: each answer is
   final. Edits per answer can come later (the key is already per answer).
5. **Receipts per answer.** The creator confirms one answer by its receipt id (`confirmAnswer`);
   replies go to an answer's receipt id as before. The respondent keeps its earlier answers privately
   (`myAnswers.earlier`) and sees how many it sent and how many were received.
6. **Rewards** count received (confirmed) answers per respondent. Anonymous forms still work (the
   anonymous identity is per form, so the per-person cap applies), but their answers can't be linked to
   a real address, so they can't be rewarded.

## Compatibility

- Existing forms: nothing changes (the field is omitted at 1; golden vectors byte-identical).
- An older creator app shows only each person's first answer to such a form (`duplicate-respondent`);
  an older respondent app allows one answer. So: publish several-answer forms once creators and
  respondents run 0.7.0+ (desktop) / the matching Android version.
