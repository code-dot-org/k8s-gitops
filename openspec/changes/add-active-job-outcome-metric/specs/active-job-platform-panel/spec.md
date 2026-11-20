## ADDED Requirements

### Requirement: The ActiveJob overview shows jobs performed by platform and outcome

The `activejob-overview` dashboard SHALL contain a time series panel titled "Jobs performed by platform", defined in code in the infrastructure repository alongside the dashboard's other panels. The panel SHALL:

- read `PerformCount` from the `code-dot-org/ActiveJob` namespace on the CloudWatch datasource
- use statistic `Sum` with a 60-second period
- show one series per `Platform` and `Outcome` pair, summed across every `JobName`
- follow the dashboard's `$environment` variable
- include new job classes without a code change
- colour the failure series so they are distinguishable from the success series at a glance

Its description SHALL state:

- what is counted: one per attempt run by a worker process, so retries count again
- what `success` means: the attempt finished without raising, including attempts a job chose to skip
- what is not counted: jobs killed mid-run, and failures before `perform` starts
- that no data means unknown, not healthy: an idle worker and a broken worker look the same

#### Scenario: Both platforms are running jobs

- **WHEN** a viewer selects `production` while EC2 and k8s workers are both completing jobs
- **THEN** the panel shows separate `ec2 success` and `k8s success` series with non-zero values

#### Scenario: The k8s worker is failing jobs

- **WHEN** jobs on the k8s worker raise
- **THEN** a `k8s failure` series rises, visibly distinct from the success series

#### Scenario: A new job class ships

- **WHEN** a job class that did not exist when the panel was written starts running
- **THEN** its performs are included in the panel's totals

#### Scenario: No data for a pair

- **WHEN** no worker on a platform has produced an outcome in the selected time range
- **THEN** that series is absent or empty, the rest of the panel still renders, and the description tells the viewer this is not evidence of health

### Requirement: The panel changes nothing else on the dashboard

Adding the panel SHALL NOT change the queries of existing panels, and SHALL NOT add an alert rule, a contact point or a notification policy.

#### Scenario: Existing panels after the change

- **WHEN** the dashboard is built after the change
- **THEN** every existing panel's queries are byte-for-byte what they were, apart from layout position
