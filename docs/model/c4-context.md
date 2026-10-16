# C4 context: the product and where it is built

The product is the Features. An engineer works in a consuming repo; its devcontainer pulls the
Features from the registry. The Features are built in the devhost, with the way of working.
Node ids are ontology ids (`external-` for what is outside the model).

```mermaid
flowchart LR
  engineer["Engineer"]
  consuming-repo["Consuming repo"]
  devcontainer["Devcontainer"]
  feature["Features"]
  feature-registry["Feature registry"]
  devhost["Devhost"]
  operator["The Operator"]
  workstation["Workstation"]
  external-github["GitHub"]
  engineer -->|uses| consuming-repo
  consuming-repo -->|contains| devcontainer
  devcontainer -->|pulls| feature
  feature-registry -->|contains| feature
  devhost -->|builds| feature
  release -->|publishes| feature
  operator -->|uses| workstation
  workstation -->|launches| devhost
  devhost -->|pushes branches to| external-github
  operator -->|merges pull requests on| external-github
  external-github -->|runs| release
```
