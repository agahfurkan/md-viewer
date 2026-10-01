# TODO

Deferred work. Viewer improvements come before editor improvements.

## Deliberately not done

- **Grammar-based syntax highlighting.** The original note was conditional ("only if accuracy
  becomes a real problem"); it hasn't. The tokenizer covers ~25 languages and is fast and
  dependency-free. Revisit if users report mis-highlighting that matters.

## Known gaps

- The editor's live preview doesn't scroll in sync with the source.
- Dragging a selection from document text into a code block doesn't extend into the block
  (code blocks are separate views); copying such a selection does include the code.
- Mermaid diagrams render through an offscreen WebKit view (no native Mermaid exists); they are
  images, so their text isn't selectable or searchable.
- Tab drag between windows (use "Move Tab to New Window" instead).

## Ideas

- Remember `<details>` open/closed state per document across launches.
- Recently closed tabs across app restarts (currently per window, per launch).
