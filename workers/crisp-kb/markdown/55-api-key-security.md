If you use OpenAI, Gemini, or Claude for AI polish, you bring your own API key. Here is how it is looked after.

### Stored In The macOS Keychain

Your key goes into the macOS Keychain, the same place the system keeps your other passwords. It is protected by your login and encrypted at rest, and no other account on the Mac can read it.

If you used an early version of EnviousWispr, your key may have started out in an older file store at `~/.enviouswispr-keys/`. The app moves it into the Keychain the next time it is used, and tidies up the old file afterwards.

### Key Safety

* Your key is never written to logs.
* Your key is never included in usage or crash data.
* Your key goes nowhere except the provider you chose, as authentication on requests to that provider.

### Removing A Key

Clear the field in Settings and the stored key goes with it. You can also revoke the key from your provider's dashboard at any time, which takes effect immediately and independently of EnviousWispr.
