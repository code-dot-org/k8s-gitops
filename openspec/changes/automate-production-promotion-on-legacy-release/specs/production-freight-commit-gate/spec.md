## MODIFIED Requirements

### Requirement: Gate applies to every promotion into production

The ancestry step SHALL run for every Promotion targeting the `production` Stage, whether created from the Kargo UI, the CLI, or by Kargo's auto-promotion from the production Warehouse. The `staging` and `test` Stages SHALL NOT carry it.

#### Scenario: Manual promotion from the UI

- **WHEN** an engineer promotes Freight to `production` from the Kargo UI
- **THEN** the ancestry step runs first and its result is visible on the Promotion

#### Scenario: Automatic promotion on a legacy release

- **WHEN** Kargo auto-promotes new Freight from the production Warehouse
- **THEN** the ancestry step runs first and passes for a correctly resolved release
- **AND** it fails the Promotion before any write, with the ahead-by message, if the resolved commit is not contained in `production`

#### Scenario: Staging and test are unaffected

- **WHEN** new Freight is auto-promoted to `staging` and `test`
- **THEN** no ancestry check runs and those promotions behave as before
