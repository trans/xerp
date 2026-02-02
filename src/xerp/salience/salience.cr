require "./counts"
require "./metrics"
require "./kind_detector"
require "./scorer"

module Xerp::Salience
  VERSION = "0.1.0"

  # TODO: Move keywords logic here from:
  #   - cli/keywords_command.cr (learning header/footer/comment patterns)
  #   - adapters/keyword_context.cr (passing patterns to adapters)
  # This should happen when we integrate adapters with kind detection,
  # so learned patterns inform both block building and classification.
end
