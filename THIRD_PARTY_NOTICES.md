# Third-Party Notices

XiangqiAssistant includes or depends on third-party components. The repository's MIT license applies only to the original XiangqiAssistant source unless a file states otherwise.

## Pikafish

- Project: https://github.com/official-pikafish/Pikafish
- Role: local Chinese-chess analysis engine and NNUE weight
- License: GNU General Public License v3.0 according to the upstream project

The bundled Pikafish executable runs as a separate UCI process. Redistribution and modification of Pikafish remain subject to its upstream license and notices.

## Microsoft ONNX Runtime

- Project: https://github.com/microsoft/onnxruntime
- Swift package: https://github.com/microsoft/onnxruntime-swift-package-manager
- Role: local inference runtime
- Version used by this project: 1.24.2
- License: MIT according to the upstream project

## TheOne1006 model files

- Files: `layout_recognition.onnx`, `pose.onnx`
- Role: board layout recognition and board-corner localization

These model files are treated as separate runtime assets. Their provenance and redistribution terms are not replaced by this repository's MIT license. Downstream distributors are responsible for confirming that their intended use and redistribution comply with the model provider's terms.

## Offline opening book

`opening_book_v1.json` is a project-authored factual compilation of conservative, commonly known Xiangqi opening branches. It does not copy or redistribute a commercial or online game database. Every record carries project provenance, is checked for legality, and remains only an input to independent Pikafish verification.
