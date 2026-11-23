# What the release lane sets in App Store Connect the first time, against a stand-in for
# Apple's API: ruby fastlane/test/store_setup_test.rb (make test-scripts).

require "minitest/autorun"
require_relative "../store_setup"

# Answers like App Store Connect: the paths it knows, "does not exist" for the others.
class FakeStore
  Response = Struct.new(:body)
  attr_reader :posts, :patches

  def initialize(known)
    @known = known
    @posts = []
    @patches = []
  end

  def get(path, _params)
    body = @known.fetch(path) { raise "The specified resource does not exist" }
    raise body if body.is_a?(StandardError)

    Response.new(body)
  end

  def post(path, body)
    @posts << [path, body]
    Response.new({})
  end

  def patch(path, body)
    @patches << [path, body]
    Response.new({})
  end
end

Group = Struct.new(:is_internal_group)

class FakeApp
  attr_reader :created

  def initialize(groups = [])
    @groups = groups
    @created = []
  end

  def id
    "123"
  end

  def get_beta_groups
    @groups
  end

  def create_beta_group(**options)
    @created << options
  end
end

POINTS = {
  "data" => [
    { "id" => "p-099", "attributes" => { "customerPrice" => "0.99" } },
    { "id" => "p-000", "attributes" => { "customerPrice" => "0.0" } },
    { "id" => "p-999", "attributes" => { "customerPrice" => "9.99" } }
  ]
}.freeze

TERRITORIES = { "data" => [{ "id" => "USA" }, { "id" => "FRA" }, { "id" => "SWE" }] }.freeze

AVAILABILITIES = "v2/appAvailabilities/123/territoryAvailabilities"

# The countries as App Store Connect lists them, available or not.
def availabilities(available)
  { "data" => available.map do |territory, on|
    { "id" => "ta-#{territory}", "attributes" => { "available" => on },
      "relationships" => { "territory" => { "data" => { "type" => "territories", "id" => territory } } } }
  end }
end

class StoreSetupTest < Minitest::Test
  def new_app_store
    FakeStore.new(
      "v1/apps/123/appPricePoints" => POINTS, "v1/territories" => TERRITORIES,
      AVAILABILITIES => availabilities("USA" => true, "FRA" => false, "SWE" => true)
    )
  end

  def prepare(app, store, france: false)
    reports = []
    StoreSetup.prepare(app, store, ->(outcome, text) { reports << [outcome, text] }, france: france)
    reports
  end

  def test_a_new_app_gets_a_group_a_free_price_and_every_country_but_france
    app = FakeApp.new
    store = new_app_store
    reports = prepare(app, store)
    assert_equal [{ group_name: "Xippi", is_internal_group: true, has_access_to_all_builds: true }], app.created
    assert_equal %w[v1/appPriceSchedules v2/appAvailabilities], store.posts.map(&:first)
    assert_equal [:done, :done, :done], reports.map(&:first)
    assert_empty store.patches
  end

  def test_the_free_price_point_is_the_one_that_costs_nothing
    assert_equal "p-000", StoreSetup.free_point(POINTS["data"])
    assert_nil StoreSetup.free_point(POINTS["data"].reject { |point| point["id"] == "p-000" })
  end

  def test_the_price_schedule_is_free_in_dollars
    body = StoreSetup.price_schedule("123", "p-000")
    assert_equal "USA", body.dig(:data, :relationships, :baseTerritory, :data, :id)
    assert_equal "p-000", body.dig(:included, 0, :relationships, :appPricePoint, :data, :id)
    assert_equal body.dig(:data, :relationships, :manualPrices, :data, 0, :id), body.dig(:included, 0, :id)
  end

  def test_france_is_the_only_country_left_out
    body = StoreSetup.availability("123", %w[USA FRA SWE])
    available = body[:included].to_h { |item| [item.dig(:relationships, :territory, :data, :id), item.dig(:attributes, :available)] }
    assert_equal({ "USA" => true, "FRA" => false, "SWE" => true }, available)
    assert_equal true, body.dig(:data, :attributes, :availableInNewTerritories)
    assert_equal body[:included].map { |item| item[:id] },
                 body.dig(:data, :relationships, :territoryAvailabilities, :data).map { |item| item[:id] }
  end

  def test_what_is_already_set_stays
    app = FakeApp.new([Group.new(true)])
    store = FakeStore.new(
      "v1/appPriceSchedules/123" => {},
      "v1/appPriceSchedules/123/manualPrices" => { "data" => [{ "id" => "a-price" }] },
      "v2/appAvailabilities/123" => {},
      AVAILABILITIES => availabilities("USA" => true, "FRA" => false, "SWE" => false)
    )
    assert_empty prepare(app, store)
    assert_empty app.created
    assert_empty store.posts
    assert_empty store.patches
  end

  # The beta.1 run: App Store Connect had made the app available everywhere, France
  # included, so the countries step found them set and left France on.
  def test_france_is_turned_off_where_app_store_connect_turned_it_on
    store = FakeStore.new(
      "v1/appPriceSchedules/123" => {},
      "v1/appPriceSchedules/123/manualPrices" => { "data" => [{ "id" => "a-price" }] },
      "v2/appAvailabilities/123" => {},
      AVAILABILITIES => availabilities("USA" => true, "FRA" => true, "SWE" => true)
    )
    reports = prepare(FakeApp.new([Group.new(true)]), store)
    assert_equal [["v1/territoryAvailabilities/ta-FRA",
                   { data: { type: "territoryAvailabilities", id: "ta-FRA", attributes: { available: false } } }]],
                 store.patches
    assert_equal [[:done, "France: turned off (no encryption declaration)"]], reports
    assert_empty store.posts
  end

  def test_with_the_encryption_declaration_france_is_left_as_it_is
    store = FakeStore.new(
      "v1/appPriceSchedules/123" => {},
      "v1/appPriceSchedules/123/manualPrices" => { "data" => [{ "id" => "a-price" }] },
      "v2/appAvailabilities/123" => {},
      AVAILABILITIES => availabilities("FRA" => true)
    )
    assert_empty prepare(FakeApp.new([Group.new(true)]), store, france: true)
    assert_empty store.patches
  end

  def test_sold_in_france_only_with_the_declaration_code
    refute StoreSetup.sold_in_france?("ITSAppUsesNonExemptEncryption" => false)
    refute StoreSetup.sold_in_france?("ITSAppUsesNonExemptEncryption" => true)
    refute StoreSetup.sold_in_france?(
      "ITSAppUsesNonExemptEncryption" => true, "ITSEncryptionExportComplianceCode" => " "
    )
    assert StoreSetup.sold_in_france?(
      "ITSAppUsesNonExemptEncryption" => true, "ITSEncryptionExportComplianceCode" => "a1b2-c3"
    )
  end

  def test_a_schedule_without_prices_gets_the_free_one
    store = new_app_store
    store.instance_variable_get(:@known).merge!(
      "v1/appPriceSchedules/123" => {}, "v1/appPriceSchedules/123/manualPrices" => { "data" => [] }
    )
    prepare(FakeApp.new([Group.new(true)]), store)
    assert_includes store.posts.map(&:first), "v1/appPriceSchedules"
  end

  def test_an_error_is_reported_and_the_other_steps_still_run
    store = FakeStore.new(
      "v1/apps/123/appPricePoints" => RuntimeError.new("forbidden"), "v1/territories" => TERRITORIES,
      AVAILABILITIES => availabilities("FRA" => false)
    )
    reports = prepare(FakeApp.new([Group.new(true)]), store)
    assert_equal [[:failed, "Price not set: forbidden. Set it in App Store Connect."]], reports.select { |outcome, _| outcome == :failed }
    assert_equal ["v2/appAvailabilities"], store.posts.map(&:first)
  end

  def test_only_does_not_exist_counts_as_missing
    store = FakeStore.new("v1/x" => RuntimeError.new("not allowed"))
    assert_raises(RuntimeError) { StoreSetup.missing?(store, "v1/x") }
    assert StoreSetup.missing?(store, "v1/y")
  end
end
