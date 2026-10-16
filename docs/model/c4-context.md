# C4 context: the product and where it is built

The product is the Features, at the centre. Read the top row first: an engineer works in a
consuming repo, its devcontainer pulls the Features, and the registry holds the released ones.
The row below is where they come from: the Operator launches the devhost from the workstation,
the devhost builds the Features and pushes branches to GitHub, and a release publishes them.
Node ids are ontology ids (`external-` for what is outside the model).

```mermaid
flowchart LR
  engineer["Engineer"]
  consuming-repo["Consuming repo"]
  devcontainer["Devcontainer"]
  feature["Features (the product)"]
  feature-registry["Feature registry"]
  operator["The Operator"]
  workstation["Workstation"]
  devhost["Devhost"]
  external-github["GitHub"]
  release["Release"]
  engineer -->|uses| consuming-repo
  consuming-repo -->|contains| devcontainer
  devcontainer -->|pulls| feature
  feature-registry -->|contains| feature
  operator -->|uses| workstation
  workstation -->|launches| devhost
  devhost -->|builds| feature
  devhost -->|pushes branches to| external-github
  operator -->|merges pull requests on| external-github
  external-github -->|runs| release
  release -->|publishes| feature
  classDef product stroke-width:3px
  class feature product
```
