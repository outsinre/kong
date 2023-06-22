-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local typedefs = require "kong.db.schema.typedefs"

-- is required false by default?
-- consumer, protocol, etc. settings
-- enabled on route AND service
return {
  name = "upstream-timeout",
  fields = {
    { protocols = typedefs.protocols_http },
    { consumer_group = typedefs.no_consumer_group },
    { config = {
      type = "record",
      fields = {
        { read_timeout = typedefs.timeout },
        { send_timeout = typedefs.timeout },
        { connect_timeout = typedefs.timeout }
      }
    }
    }
  }
}
