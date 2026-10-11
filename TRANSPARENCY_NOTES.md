# Transparency notes

This package contains the final Microsoft-developed Aion 1.0 Instruct small language model
planned for release with Windows. The package itself is a pre-release developer validation
package for the new Aion Instruct model stack, not the final Windows delivery.

It is not for end-user or customer use. Do not ship any part of this package to end consumers.

Although the model is final, this validation package may:

- Contain incomplete or unoptimized functionality.
- Produce inaccurate, inconsistent, or unexpected outputs.
- Differ in runtime performance, integration, APIs, or available functionality from the final
  Windows delivery.

The model and SDK are provided as-is without guarantees of accuracy, reliability, availability,
or fitness for a particular purpose. Performance measured with this preview is not representative
of the final Windows release.

## Intended use

This package is intended exclusively for application developers to validate integration with the
Aion Instruct model stack before its Windows release. Validation scenarios include:

- Text generation
- Rewriting
- Summarization
- Multi-turn conversation
- Image description

These examples describe functionality developers can evaluate; they do not establish Responsible
AI compliance or suitability for production use. Developers should evaluate output quality,
safety, and behavioral differences from Phi Silica in their own application scenarios.

Model outputs should be reviewed and validated by a human before being relied upon. This
validation package is not for end-user or customer use and must not be shipped to end consumers.

## Responsible AI evaluation

This package has not been thoroughly tested for Responsible AI compliance. In particular:

- Cross-prompt injection attacks are untested.
- Emotional inference is untested.
- The package may have vulnerabilities.

Application developers remain responsible for evaluating their scenarios and applying
appropriate safeguards. The included moderation behavior does not establish Responsible AI
qualification or guarantee safe or accurate output.

## Not recommended for

This release must not be used for:

- Medical, legal, financial, or other high-impact decision making
- Safety-critical systems or automated operational control
- Generating harmful, violent, explicit, abusive, or illegal content
- Deceptive or misleading activities, including misinformation, impersonation, fraud, or spam
- Fully autonomous actions without appropriate human oversight
- Production workloads requiring guaranteed accuracy, reliability, or deterministic behavior

## Model behavior and limitations

Like other small language models, Aion Instruct may:

- Hallucinate or generate factually incorrect information
- Reflect biases or limitations present in training data
- Fail to follow instructions consistently
- Generate incomplete, malformed, or low-quality outputs

As a new model, Aion Instruct has behavioral changes compared with Phi Silica. Application
developers must not rely on deterministic output.

Performance, latency, memory usage, and output quality may vary depending on device hardware and
configuration. AMD support will be added soon.

## Watermarking

The new model stack uses invisible watermarking to support compliance with the EU AI Act. The
watermark may become visible when model output is pasted into certain applications or locations.

## LoRA compatibility

Phi Silica-compatible LoRAs are not compatible with Aion Instruct. Developers who use custom
LoRAs must use Foundry Toolkit to create new custom LoRAs for Aion Instruct.
This preview sample API does not expose LoRA configuration.

## Distribution and runtime notes

This release may include hardware-specific compiled or cached model artifacts generated locally
on the device during runtime initialization. These artifacts are intended solely for local
execution and evaluation as part of the model's runtime environment.

## Feedback

We welcome developer feedback and experimentation results to help improve future versions of the
model and the Windows AI platform.
