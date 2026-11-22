# What App Store Connect needs before a build is tested or reviewed, set by the release lane
# only where nothing is set yet, so whatever is changed there later (a price, France) stays:
# - an internal TestFlight group that gets every build;
# - a price: free;
# - the countries: every one but France, until the ANSSI declaration
#   (docs/app-store-setup.md), and any Apple adds later.
# A step that fails is reported with what to set by hand, and the run goes on: a TestFlight
# build needs none of it, and App Review refuses a version that lacks one.
#
# `client` answers get(path, params) and post(path, body) as spaceship's App Store Connect
# client does; `app` is spaceship's app.
module StoreSetup
  TESTERS = "Xippi"
  # The price is set in this territory's currency; everywhere else follows it.
  BASE_TERRITORY = "USA"
  NOT_SOLD_IN = ["FRA"].freeze

  module_function

  # `report` takes (:done or :failed, text).
  def prepare(app, client, report)
    {
      "TestFlight group" => -> { tester_group(app) },
      "Price" => -> { first_price(app, client) },
      "Countries" => -> { first_countries(app, client) }
    }.each do |what, step|
      done = step.call
      report.call(:done, "#{what}: #{done}") if done
    rescue StandardError => e
      report.call(:failed, "#{what} not set: #{e.message}. Set it in App Store Connect.")
    end
  end

  # Whether App Store Connect has nothing at that address: it answers "does not exist".
  def missing?(client, path)
    client.get(path, nil)
    false
  rescue StandardError => e
    raise unless e.message =~ /does not exist|not found/i

    true
  end

  def tester_group(app)
    return nil if app.get_beta_groups.any?(&:is_internal_group)

    app.create_beta_group(group_name: TESTERS, is_internal_group: true, has_access_to_all_builds: true)
    "#{TESTERS}, every build"
  end

  def first_price(app, client)
    return nil unless missing?(client, "v1/appPriceSchedules/#{app.id}") ||
                      client.get("v1/appPriceSchedules/#{app.id}/manualPrices", { limit: 1 }).body["data"].empty?

    points = client.get("v1/apps/#{app.id}/appPricePoints", { filter: { territory: BASE_TERRITORY }, limit: 200 })
    free = free_point(points.body["data"])
    raise "no free price point in #{BASE_TERRITORY}" unless free

    client.post("v1/appPriceSchedules", price_schedule(app.id, free))
    "free"
  end

  def first_countries(app, client)
    return nil unless missing?(client, "v2/appAvailabilities/#{app.id}")

    territories = client.get("v1/territories", { limit: 200 }).body["data"].map { |territory| territory["id"] }
    client.post("v2/appAvailabilities", availability(app.id, territories))
    "every one but #{NOT_SOLD_IN.join(', ')}"
  end

  # The id of the price point that costs nothing.
  def free_point(points)
    points.find { |point| point.dig("attributes", "customerPrice").to_s.match?(/\A0+(\.0+)?\z/) }&.dig("id")
  end

  def price_schedule(app_id, point_id)
    {
      data: {
        type: "appPriceSchedules",
        relationships: {
          app: { data: { type: "apps", id: app_id } },
          baseTerritory: { data: { type: "territories", id: BASE_TERRITORY } },
          manualPrices: { data: [{ type: "appPrices", id: "${free}" }] }
        }
      },
      included: [{
        type: "appPrices", id: "${free}", attributes: { startDate: nil },
        relationships: { appPricePoint: { data: { type: "appPricePoints", id: point_id } } }
      }]
    }
  end

  def availability(app_id, territories)
    included = territories.map do |territory|
      {
        type: "territoryAvailabilities", id: "${#{territory}}",
        attributes: { available: !NOT_SOLD_IN.include?(territory) },
        relationships: { territory: { data: { type: "territories", id: territory } } }
      }
    end
    {
      data: {
        type: "appAvailabilities",
        attributes: { availableInNewTerritories: true },
        relationships: {
          app: { data: { type: "apps", id: app_id } },
          territoryAvailabilities: { data: included.map { |item| item.slice(:type, :id) } }
        }
      },
      included: included
    }
  end
end
