typealias RecentPowerHistoryModel = HistoryQueryModel<[RecentPowerSample]>

extension HistoryQueryModel where Value == [RecentPowerSample] {
    var samples: [RecentPowerSample] { data ?? [] }
}
