/// Prompt style family. Maps (provider, model identity, execution location) to a prompt
/// construction strategy. Builder selection goes through `PromptFamily`, not raw provider.
///
/// Lives in Core, not LLM, because `PolishPlan` (Core) carries the selected family so the
/// decision is made exactly once — `EnviousWisprCore` declares no dependencies, so a Core
/// type cannot reference an LLM one (#1948).
///
/// #1948 collapsed the two Ollama families (`openAIProse`, `gemmaFewShot`) into a single
/// `localFixed`. Those two selected a per-transcript `PolishMode` whose `.inline` variant
/// instructed "Keep as one paragraph, no formatting" — measured on the real rendered
/// production prompts, `.inline` was chosen for 1,548 of 1,690 corpus cases, so 92% of
/// dictations received an instruction contradicting the formatting the product promises.
/// That is the defect #1255 fixed for cloud and had never been fixed for Ollama.
public enum PromptFamily: String, Sendable {
  /// One fixed prompt for the strong cloud providers (OpenAI, Gemini, Claude) and for
  /// HOSTED Ollama models, which run on Ollama's servers rather than the user's Mac and
  /// are frontier-class. No per-transcript mode selection — formatting is decided by
  /// in-prompt rules, like Apple Intelligence (#1255, extended to hosted Ollama by #1948).
  case cloudFixed

  /// One fixed prompt for every Ollama model executing ON the user's Mac, regardless of
  /// size or name (#1948). Replaces the `openAIProse` / `gemmaFewShot` name heuristics.
  /// Canonical text: `scripts/eval/prompts/ollama-local-polish-prompt-L3.txt`.
  case localFixed

  /// The exact training prompt for EG-1, the EnviousWispr-tuned local model served via
  /// Ollama (#1269) or by the bundled first-party server (#1271). Mode-independent like
  /// `cloudFixed`; the tuned behaviors live in the model weights, and the prompt must
  /// match training byte-for-byte.
  case egOneFixed

  /// EG-1's training prompt from version 1.2 onward. It extends `egOneFixed` with the
  /// greeting/sign-off envelope rule and three worked self-correction examples, and it is
  /// the prompt the 1.2 weights were tuned on. The two cases must coexist: a user still
  /// holding 1.1 bytes has to keep receiving 1.1's prompt, because the artifact and its
  /// prompt are one contract: a model may only ever be sent the instruction it was
  /// tuned on, so a prompt change is a new template id and a new case, never an edit.
  /// Selected from the shipped manifest's `promptTemplateID`, never from the model's name.
  /// Canonical text: `scripts/eval/prompts/eg1-polish-prompt-v2.txt`.
  case egOneEnvelope
}
