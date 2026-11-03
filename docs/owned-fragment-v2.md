# Ghost owned-fragment v2 — implementation specification

Date: 2026-11-03. Author: DiscussionBridge. Component-format definition for the
native Ghost connector. This documents pure preparation/extraction helpers, not
completed native synchronization, ownership recovery or public verification.
Those callers must retain intent and obtain current authority before effects.
No old v1 object/receipt adoption or conversion is authorized. Shared receiver
and V4 wire protocol remain unchanged. This is not another product work list.

## Profile and dependencies

The profile is `ghost-owned-fragment-v2`, not v1 and not the separate
`ghost-dynamic-1` attention-observation profile. Use Core's existing Nokogiri
1.19.4 HTML5 parser on the pinned Core `acf8e701`; never silently fall back to
HTML4, an unavailable parser, or a different parser version. No new runtime
Node process or dependency installation. The Core lock's existing Linux gnu/musl
platform variants must produce the same golden vectors. Unsupported/mismatching
parser means explicit attention, not a fabricated proof. A future parser change
needs exact compatibility vectors or a separately versioned component profile.

Input is strict UTF-8 bytes (no BOM, NUL, replacement decoding or encoding guess).
The caller supplies the positive byte ceiling from the actual content/public
read budget; do not reuse the small receiver JSON ceiling for a complete page.
Explicit HTML5 options: UTF-8 encoding, body-context fragment for an HTML card,
document parse for an anonymous public page, scripting-enabled noscript text,
tree depth 400, attributes per element 400. Representation/resource-limit
failure is reported and retained; no trimming or automatic sanitization follows.
Use up to 100 parse-error observations. Card/raw-span parse errors are fatal;
unrelated public-theme errors cannot authorize altered owned content. Public
owned section must match its independently parsed raw span and expected content.
This extractor is NOT the source-preservation or sanitizer implementation.

## Retained binding and delimiters

One binding contains canonical lowercase resource UUID, native kind `post` or
`page`, native 24-lowercase-hex ID, and a 64-lowercase-hex fragment nonce. Before
the single initial draft create, native ID may instead be exactly `pending`.
The draft path is never accepted as a published/public proof. Generate nonce
once and persist it with the exact initial native intent BEFORE any effect;
reuse it for that native object's lifetime, including retries and revisions.
It is public correlation data, not a credential or grant. It is distinct from
receiver-issued publication URL-move proof nonces.

Exact safe-ASCII delimiters, immediately adjacent to one section, are:

```html
<!--discussionbridge-owned:v2:begin:RESOURCE:KIND:NATIVE:NONCE--><section ...>...</section><!--discussionbridge-owned:v2:end:RESOURCE:KIND:NATIVE:NONCE-->
```

The section carries exact `data-discussionbridge-owned` profile, resource,
native ID, and fragment nonce attributes; source revision and presentation mode
are checked against current expected values before digest comparison. This does
not redefine the existing mode enum. URL-move attributes, if present, are
additional independent evidence, not substitutes for the retained fragment
binding. The caller obtains binding/expected identity from protected retained
intent/receipt plus current authority, never by trusting page markers alone.

## Raw/DOM agreement

Work on the original UTF-8 string's BINARY view for all offsets and slices.
There must be exactly two reserved raw delimiter prefixes, exactly one expected
begin and one expected end, in order. Other case variants, partial/nested pairs,
reserved-marker content or duplicates anywhere in the card/page fail closed.
The matching strings must also be ACTUAL parsed comment nodes, with the same
parent and immediately bracketing the unique owned HTML section. No active or
inactive second `data-discussionbridge-owned` element is allowed anywhere.

Reject hidden/inert/aria-hidden/display:none/visibility:hidden ancestry and
template/noscript/raw-text/iframe/foreign SVG or MathML ownership contexts.
Reject comments occurring in a script, textarea, attribute, escaped text,
another card, or parser-repaired ownership context. Independently parse the raw
byte span; its only nodes must be the expected comment, exact section and exact
comment. Full-context section tokens and raw-span section tokens must agree.
Do not infer offsets from DOM serialization, Ruby character indexes or regex
matching of arbitrary opening/closing HTML tags.

## Canonical bytes

Canonical value is an array with fixed order:
`[PROFILE, "nokogiri-html5-1.19.4", RESOURCE, KIND, NATIVE, NONCE, TOKENS]`.
Tokens are depth-first ordered arrays: `["open", NAMESPACE_URI, LOCAL_NAME,
ATTRIBUTES]`, `["text", DECODED_TEXT]`, `["close", NAMESPACE_URI, LOCAL_NAME]`.
For HTML nodes without an explicit namespace, use
`http://www.w3.org/1999/xhtml`. Attributes are arrays
`[NAMESPACE_URI_OR_EMPTY, LOCAL_NAME, DECODED_VALUE]`, including namespace
declarations in the XMLNS namespace, sorted lexicographically by UTF-8 bytes of
namespace then local name. Preserve all attribute values, text and whitespace;
HTML5 entity/newline semantics apply without extra normalization. Ordinary
comments produce no tokens. Binding comments are separately validated above.
All other node kinds inside the owned section fail closed.

Serialize this nested array as compact UTF-8 JSON, no ASCII-only conversion,
no insignificant spaces, no slash escaping: quote/backslash escaped, backspace,
tab, LF, formfeed, CR use their JSON short escapes, remaining C0 controls use
lowercase four-digit Unicode escapes. SHA-256 those bytes. Golden vectors must
pin entities, CRLF, all controls accepted by HTML5, Unicode, attribute ordering,
tables/tbody, code/math/Mermaid text and namespace handling. Equality alone does
not prove source preservation: preparation must separately compare meaningful
source/native conversion and report named lost functions rather than success.

## Lexical surgery and native/public qualification

New content uses one native Ghost HTML card v1. For update, require current
native ID/type and updated_at CAS, retained ownership/baseline, and exactly one
matching HTML card in the native Lexical root. Extract its owned span and the
Admin-rendered span and require same-profile equality. Replace only that raw
span with the prepared replacement span. Preserve every other Lexical value,
card property, unrelated card, and exact decoded HTML prefix/suffix byte. This
does not claim identical outer JSON escaping/key order. Never rewrap rendered
Ghost HTML or serialize a full DOM/card to effect an update.

Persist old baseline/markers, desired exact bytes and expected native revision
before CAS. Unknown create/update outcomes inspect both posts AND pages using
retained intent; no second create, append, automatic adoption, nonce rotation or
v1 conversion. Changed/missing/partial/conflicting ownership means attention.
Current native authorization, protected receipt and CAS remain necessary even
if a third party copied all public markers.

Anonymous exact canonical HTTP200 must expose the same expected owned fragment,
revision/mode/source and required discussion presentation; Admin/Lexical/source
SHA/marker presence alone is insufficient. Keep synchronized vs verified distinct.
Public comment removal or Ghost/theme rendering changes fail explicitly. Browser
qualification remains necessary for actual frame/session/rich-content behavior;
this parser cannot prove a reply editor works. Withdrawal requires owned native
unpublish plus exact public URL404/410. Existing v1 objects and receipts stay
untouched and cannot be adopted merely because the new connector has no state.

## Primary-source basis and consultation limits

Nokogiri API/options: https://nokogiri.org/rdoc/Nokogiri/HTML5.html and
https://nokogiri.org/rdoc/Nokogiri/HTML5/DocumentFragment.html, read2026-11-03.
Exact Core lock independently read through GitHub Contents pins1.19.4; docs are
API guidance, not evidence of successful local parsing. Windows Nokogiri is not
installed; native CI will execute actual Core parser vectors. New Bridge Boss's
GHOST-OWNED-FRAGMENT-V2-DESIGN-20261103 consultation identifies preservation and
adversarial properties; it issued no source/runtime acceptance. This component definition fixes the helper format only; it does not qualify
its downstream callers. Any discovered need to depart
from approved content/identity/recovery behavior goes back to Phil.
