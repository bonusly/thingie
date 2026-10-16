Blueprinter.configure do |config|
  config.generator = Oj if defined?(Oj)
  config.sort_fields_by = :definition
  config.datetime_format = ->(time) { time&.iso8601 }
  config.if = ->(_field_name, _object, options) { !options[:omit_nil] }
end

module BlueprintCollectionMeta
  def render_page(records, total:, page:, per_page:, **options)
    {
      data: render_as_hash(records, **options),
      meta: { total: total, page: page, per_page: per_page, pages: (total.to_f / per_page).ceil }
    }
  end
end

Blueprinter::Base.extend(BlueprintCollectionMeta)
