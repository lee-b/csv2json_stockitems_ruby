require 'csv'
require 'json'
require 'logger'

$USE_RELAXED_NULLS = true
$USE_RELAXED_CURRENCY = true

require 'bigdecimal'

$err_log = Logger.new(STDERR)
$err_log.level = Logger::WARN

# 
# Does the overall work of converting a CSV file to a JSON file.
#
# Takes 3 arguments:
#
#     srcCsvFname       The CSV file to read
#     dstJsonFname      The JSON file to create
#     row_mapper        This is a function which maps the input CSV row
#                       to a JSON object (dict, list, etc.)
#
# Each CSV item is read from the input CSV file, mapped via the row_mapper,
# into a JSON item, and written into a JSON list within the output file.
# That is: the output file will look like [ item1, item2, item3 ], and each
# item will be whatever Ruby's built-in JSON serialiser thinks the item
# returned from row_mapper should look like.
#
def do_stockitem_csv2json_conversion(srcCsvFname, dstJsonFname, row_mapper)
    out_fp = open(dstJsonFname, "w")

    $err_log.debug("Reading #{srcCsvFname}; outputting to #{dstJsonFname}")

    items_written = 0

    out_fp.write("[\n")
    CSV.foreach(srcCsvFname, headers: true) do |csv_record|
        $err_log.debug("Processing item #{items_written + 1}")

        if items_written > 0
            out_fp.write(",\n")
        end

        json_row = row_mapper.call(csv_record)
	 	out_fp.write(JSON.pretty_generate(json_row, :space_before => "    "))

        items_written += 1
    end
    out_fp.write("\n]\n")

ensure
    out_fp.close()

end

#
# Take a dictionary with keys like:
#
#   groupname_1_fieldname:          "a",
#   groupname_1_otherfieldname:     "b",
#   groupname_2_fieldname:          "c",
#   groupname_2_otherfieldname:     "d",
#
# and remap it to:
#
#   groupname: {
#       "1": {
#           "fieldname":      ...
#           "otherfieldname": ...
#       },
#       "2": {
#           "fieldname":      ...
#           "otherfieldname": ...
#       },
#   }
#
# Also supports renaming groupnames, if a custom mapper function is provided
#
def raise_keys_to_hashes(orig_dict, pattern, group_name_remapper = lambda { |x| x })
    new_dict = {}

    orig_dict.each { |k,v|
        m = pattern.match(k)
        if m
            group_name = group_name_remapper.call(m[1])
            group_idx = m[2]
            group_idx_field = m[3]

            $err_log.debug("raise_keys_to_hashes: m matched; it is #{m.inspect}")
            $err_log.debug("group_name is #{group_name}; group_idx is #{group_idx}; group_idx_field is #{group_idx_field}")

            if not new_dict.has_key?(group_name)
                new_dict[group_name] = {}
            end

            if not new_dict[group_name].has_key?(group_idx)
                new_dict[group_name][group_idx] = {}
            end

            new_dict[group_name][group_idx][group_idx_field] = v

        else
            $err_log.debug("raise_keys_to_hashes: key #{k} not matched; passing value #{v} through.")
            new_dict[k] = v

        end
    }

    return new_dict
end

# Takes a dictionary like:
#
# {
#    "1": {
#        "a": ...
#        "b": ...
#    },
#    "2": {
#        "a": ...
#        "b": ...
#    }
# }
#
# And converts it to a list like:
#
# [
#    {
#        "a": ...
#        "b": ...
#    },
#    {
#        "a": ...
#        "b": ...
#    }
# }
#
# whilst respecting the sort order of keys
#

def collapse_indexed_hashes_to_list(indexed_hash)
    res = []

    keys = indexed_hash.keys()
    keys.sort()

    keys.each { |k|
        res.push(indexed_hash[k])
    }

    return res
end

# Simple predicate which checks whether a given modifier's name is nil
# I use this to determine whether modifiers are "empty" and should be removed
# from the JSON file's "modifiers" list.
def modifier_name_is_nil(mod_name, mod_fields)
    mod_fields.each { |k,v|
        match = k == "name"

        if $USE_RELAXED_NULLS
            match &&= v == "nil"
        else
            match &&= v == nil
        end

        if match
            return true
        end
    }

    return false
end

# Takes one hash (aka hashset / map / dictionary), and copies it verbatim to
# a new hash, EXCEPT where matching keys are found in the given
# key_to_lambda_map.  For each matching key in key_to_lambda_map, the
# associated value is treated as a function to call, which maps the old value
# from the original hash (i.e., orig_hash[key]) to a new value in the new
# hash (i.e., return_value[key])
def apply_matched_lambdas_on_keys(key_to_lambda_map, orig_hash)
    new_hash = {}

    orig_hash.each { |k,v|
        catch :early_map_return do
            key_to_lambda_map.each{ |lmk,lmv|
                if lmk.match(k)
                    mapper = key_to_lambda_map[lmk]

                    new_hash[k] = mapper.call(v)
                    $err_log.debug("Mapped key '#{k}' (value '#{v}') to value '#{new_hash[k]}'")

                    throw :early_map_return
                end
            }

            $err_log.debug("Passing through key '#{k}' (value '#{v}')")
            new_hash[k] = v
        end
    }

    return new_hash
end

# Parser for CSV quantities, to make them suit our desired internal format / 
# JSON output format
# Basically, we convert nil values to some form of nil (according t
# compatibility / strictness settings), and anything else to an int.
def csv_quantity_parser(quan_str)
    if quan_str == nil
        if $USE_RELAXED_NULLS == true
            return "nil"
        else
            return nil
        end
    else
        return quan_str.to_i
    end
end

# Parser for CSV prices, to make them suit our desired internal format / 
# JSON output format
# Basically, we convert nil values to some form of nil (according t
# compatibility / strictness settings), and anything else to a number with
# fractions.  If USE_RELAXED_MONEY is set, then we use floating point.
# Otherwise, we use BigDecimals for greater accuracy.
def csv_price_parser(price_str)
    $err_log.debug("csv_price_parser(#{price_str}): called")

    # handle nils
    if price_str == "" or price_str == nil
        $err_log.debug("csv_price_parser(#{price_str}): returning nil")
        if $USE_RELAXED_NULLS == true
            return "nil"
        else
            return nil
        end
    end

    # remove, but track, the signedness
    is_neg = false

    if price_str.start_with?("-")
        $err_log.debug("csv_price_parser(#{price_str}): is negative")
        is_neg = true
        price_str = price_str[1..-1]
    end

    # remove the dollar sign without tracking it, since our output format
    # doesn't seem to care about currency, and our input format doesn't seem
    # to care ALL the time, either
    if price_str.start_with?("$")
        $err_log.debug("csv_price_parser(#{price_str}): has dollar")
        price_str = price_str[1..-1]
    end

    # use floating point or big decimal, depending on compatibility /
    # strictness-level settings
    if $USE_RELAXED_CURRENCY == true
        val = price_str.to_f
    else
        val = BigDecimal.new(price_str)
    end

    # apply the negative sign that we tracked from earlier, if any
    if is_neg
        val = -val
    end

    $err_log.debug("csv_price_parser(#{price_str}): returning val #{val.inspect}")

    return val
end

# Parser for CSV strings, to make them suit our desired internal format / 
# JSON output format
def csv_string_parser(s)
    if s == nil
        if $USE_RELAXED_NULLS == true
            return "nil"
        else
            return nil
        end
    else
        return s
    end
end

# Main mapper function (for use with do_stockitem_csv2json_conversion), which
# takes a CSV row and converts it to a JSON row.
#
# NOTE that, while relatively complex, this does pretty much all the
# conversion necessary for a stock item, reusing code from elsewhere, in
# around 50 lines (many of which are comments, debug logging, etc.)
#
# There are around 18 lines of actual code here, which do all the work of
# importing stock items.  Adding other importers, for other types of item,
# using this code as a base, would ONLY require a similar number of lines to
# be added, along with some command-line tool which either chooses which
# mapping function to call for a particular data type, or has been modified
# with about 1 line of changes, to only process that datatype instead of
# stock items.
#
# NOTE ALSO That the code below is largely declarative, defining mappings
#           from field names to converters, and a few pre-existing functions
#           which do the remaining steps necessary to complete the conversion.
#
#           As such, it would be relatively simple to abstract this further in
#           future, with configuration files defining the same steps that this
#           function currently performs, or that other functions would
#           currently perform, for other item types.
#
def stockitem_mapper(row)
    # fields, and the first-stage field-mapping functions which should be
    # applied to them.  This does the basic work of converting strings to
    # ints, prices, and so on.  The field-mapping functions handle things like
    # 'nil', too.
    stockitem_mappings = {
        /^item id$/                 =>   lambda { |x| x.to_i },
        /^modifier_[0-9]+_name$/    =>   lambda { |x| csv_string_parser(x) },
        /^price$/                   =>   lambda { |x| csv_price_parser(x) },
        /^modifier_[0-9]+_price$/   =>   lambda { |x| csv_price_parser(x) },
        /^cost$/                    =>   lambda { |x| csv_price_parser(x) },
        /^quantity_on_hand$/        =>   lambda { |x| csv_quantity_parser(x) }
    }

    ##########################################################################
    # convert / raise fields like:
    #
    #     modifier_1_name: "x"
    #
    # into the higher-level representation:
    #
    #     "modifiers" => { "1" => { "name": x } }
    #
    # NOTE That this is NOT yet our final representation for modifiers; we
    #      convert a little more in the next step.
    #
    key_to_hash_pattern = /^(modifier)_([0-9]+)_([a-zA-Z_]+)$/
    type_converted_fields = apply_matched_lambdas_on_keys(stockitem_mappings, row)

    $err_log.debug("type_converted_fields are currently #{type_converted_fields.inspect}")

    # define a mapping function which renames the "modifier" field (a field
    # generated by raise_keys_to_hashes() using the first grouping in the
    # key_to_hash_pattern regex above) to "modifiers"
    modifier_to_modifiers = lambda { |k| k == "modifier" ? "modifiers" : k }

    final_dict = raise_keys_to_hashes(type_converted_fields, key_to_hash_pattern, group_name_remapper=modifier_to_modifiers)

    $err_log.debug("final_dict is currently #{final_dict.inspect}")

    # end main conversion / field-raising
    ##########################################################################

    # process modifiers more, if they exist, so we get our final,
    # output-compatible representation
    if final_dict.has_key?('modifiers')
        # remove empty modifier entries
        final_dict['modifiers'].delete_if { |k,v| modifier_name_is_nil(k,v) }

        # collapse the { "1" => modifier1, "2" => modifier2 } dict
        # back down to a simple list of modifiers
        new_mods = collapse_indexed_hashes_to_list(final_dict['modifiers'])
        final_dict["modifiers"] = new_mods
    end

    $err_log.debug("final_dict is currently #{final_dict.inspect}")
    $err_log.debug("final_dict.price is #{final_dict['price']}")
    $err_log.debug("final_dict.cost is #{final_dict['cost']}")

    return final_dict
end
