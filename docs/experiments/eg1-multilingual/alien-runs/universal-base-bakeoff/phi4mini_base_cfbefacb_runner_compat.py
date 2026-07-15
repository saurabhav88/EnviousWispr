from __future__ import annotations

import runpy

from transformers.models.phi3.modeling_phi3 import Phi3ForCausalLM


_original_generate = Phi3ForCausalLM.generate


def _generate_with_phi_end_tokens(self, *args, **kwargs):
    configured = self.generation_config.eos_token_id
    if configured == [200020, 199999] and kwargs.get("eos_token_id") == 199999:
        kwargs["eos_token_id"] = configured
    return _original_generate(self, *args, **kwargs)


Phi3ForCausalLM.generate = _generate_with_phi_end_tokens
runpy.run_path(
    r"C:\Users\saura\eg1-overnight\eg1_multilingual_runner.py",
    run_name="__main__",
)
