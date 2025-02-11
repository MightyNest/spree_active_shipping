module Spree
  module Calculator::Shipping
    module Usps
      class Base < Spree::Calculator::Shipping::ActiveShipping::Base

        SERVICE_CODE_PREFIX ||= {
          international: 'intl',
          domestic: 'dom'
        }

        def compute_package(package)
          order = package.order
          stock_location = package.stock_location

          origin = build_location(stock_location)
          destination = build_location(order.ship_address)

          rates_result = retrieve_rates_from_cache(package, origin, destination)

          return nil if rates_result.kind_of?(Spree::ShippingError)
          return nil if rates_result.empty?
          rate = rates_result[self.class.service_code]

          return nil unless rate
          rate = rate.to_f + (Spree::ActiveShipping::Config[:handling_fee].to_f || 0.0)

          # divide by 100 since active_shipping rates are expressed as cents
          return rate/100.0
        end

        def carrier
          carrier_details = {
            login: Spree::ActiveShipping::Config[:usps_login],
            test: Spree::ActiveShipping::Config[:test_mode]
          }

          ::ActiveShipping::USPS.new(carrier_details)
        end

        private

        def retrieve_rates(origin, destination, shipment_packages)
          begin
            response = carrier.find_rates(origin, destination, shipment_packages, rate_options)
            # turn this beastly array into a nice little hash
            service_code_prefix_key = response.params.keys.first == 'IntlRateV2Response' ? :international : :domestic
            rates = response.rates.collect do |rate|
              service_code = "#{SERVICE_CODE_PREFIX[service_code_prefix_key]}:#{rate.service_code}"
              [service_code, rate.price]
            end
            rate_hash = Hash[*rates.flatten]
            return rate_hash
          rescue ::ActiveShipping::Error => e

            if e.is_a?(::ActiveShipping::ResponseError) && e.response.is_a?(::ActiveShipping::Response)
              params = e.response.params
            
              Rails.logger.debug "ActiveShipping error base usps: #{params.inspect}"

              if params['Response']['Error']['ErrorDescription'].present?
                message = params['Response']['Error']['ErrorDescription']
              elsif params['eparcel']["error"]["statusMessage"].present?
                # Canada Post specific error message
                message = params['eparcel']["error"]["statusMessage"]
              else
                message = e.message
              end
            else
              message = e.message
            end

            error = Spree::ShippingError.new("#{I18n.t(:shipping_error)}: #{message}")
            Rails.cache.write @cache_key, error #write error to cache to prevent constant re-lookups
            raise error
          end

        end

        protected
        # weight limit in ounces or zero (if there is no limit)
        def max_weight_for_country(country)
          1120  # 70 lbs
        end

        def rate_options
          if Spree::ActiveShipping::Config[:usps_commercial_plus]
            { commercial_plus: true }
          elsif Spree::ActiveShipping::Config[:usps_commercial_base]
            { commercial_base: true }
          else
            {}
          end
        end
      end
    end
  end
end
