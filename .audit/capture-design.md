# Selected capture design

Use the Sol candidate as the implementation contract. The independent Astra judge scored Sol 24/25, Astra 23/25, and Luna 13/25 against the five criteria in capture-design-brief.md. The parent agrees. Cross-family independence could not be verified because the parent model family is not exposed.

Smart Eraser is a rectangular annotation. Renderer owns its local background estimate, patch cache, and protection rules. All-order sample exclusions remain separate from prior-only output clipping. The sample ring never reads the erased interior. Protected samples and display gaps are excluded. Too few valid samples, excessive residuals, or resource failures produce an opaque cover.

Graft Astra's bounded source sampling and compact gradient patch into Sol's renderer contract. Use a robust affine RGB fit for plain and smooth-gradient screenshot backgrounds. Interpolate the compact patch explicitly. This avoids image-sized computation during every pointer update. Do not promise arbitrary photograph repair.

EditorDocument owns a style gesture's fixed target and before-state. Keep applyStyle as the single mutation path. TrackingSlider brackets native tracking, while continuous actions update the authoritative document. End records one history entry. Defaults stay outside document history. Popover preview, numeric values, and selected swatches derive from that same style.

The circular magnifier keeps source sampling and placement. Output metadata belongs to EditorSession and comes from capture settings. Preserve explicit save opt-outs. CaptureSound owns a generated 90 ms shutter sample and plays only after complete output success. Settings offers a sound preview.

Implementation separates eraser/rendering and style/history into private Git worktrees. The parent integrates both, updates documentation, and runs the complete native campaign after all features are present.

GitHub repository visibility is PUBLIC. Standard macos-15 compute is free under the verified GitHub runner policy. Dispatch validation with store_artifacts=false and build_package=false. Preserve both workflow disabled states when finished.
