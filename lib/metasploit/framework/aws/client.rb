require 'openssl'

module Metasploit
  module Framework
    module Aws
      module Client
        include Msf::Exploit::Remote::HttpClient
        def register_autofilter_ports(ports=[]); end
        def register_autofilter_hosts(ports=[]); end
        def register_autofilter_services(services=[]); end

        def hexdigest(value)
          digest = OpenSSL::Digest::SHA256.new
          if value.respond_to?(:read)
            chunk = nil
            chunk_size = 1024 * 1024 # 1 megabyte
            digest.update(chunk) while chunk = value.read(chunk_size)
            value.rewind
          else
            digest.update(value)
          end
          digest.hexdigest
        end

        def hmac(key, value)
          OpenSSL::HMAC.digest(OpenSSL::Digest.new('sha256'), key, value)
        end

        def hexhmac(key, value)
          OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), key, value)
        end


        def request_to_sign(headers, body_digest)
          headers_block = headers.sort_by(&:first).map do |k,v|
            v = "#{v},#{v}" if k == 'Host'
            "#{k.downcase}:#{v}"
          end.join("\n")
          headers_list = headers.keys.sort.map(&:downcase).join(';')
          flat_request = [ "POST", "/", '', headers_block + "\n", headers_list, body_digest].join("\n")
          [headers_list, flat_request]
        end


        def sign(creds, service, headers, body_digest, now)
          date_mac = hmac("AWS4" + creds['SecretAccessKey'], now[0, 8])
          region_mac = hmac(date_mac, datastore['Region'])
          service_mac = hmac(region_mac, service)
          credentials_mac = hmac(service_mac, 'aws4_request')
          headers_list, flat_request = request_to_sign(headers, body_digest)
          doc = "AWS4-HMAC-SHA256\n#{now}\n#{now[0, 8]}/#{datastore['Region']}/#{service}/aws4_request\n#{hexdigest(flat_request)}"

          signature = hexhmac(credentials_mac, doc)
          [headers_list, signature]
        end

        def auth(creds, service, headers, body_digest, now)
          headers_list, signature = sign(creds, service, headers, body_digest, now)
          "AWS4-HMAC-SHA256 Credential=#{creds['AccessKeyId']}/#{now[0, 8]}/#{datastore['Region']}/#{service}/aws4_request, SignedHeaders=#{headers_list}, Signature=#{signature}"
        end

        def body(vars_post)
          pstr = ""
          vars_post.each_pair do |var,val|
            pstr << '&' if pstr.length > 0
            pstr << var
            pstr << '='
            pstr << val
          end
          pstr
        end

        def headers(creds, service, body_digest, body_length)
          now = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
          headers = {
            'Content-Type' => 'application/x-www-form-urlencoded; charset=utf-8',
            'Accept-Encoding' => '',
            'User-Agent' => "aws-sdk-ruby2/2.6.27 ruby/2.3.2 x86_64-darwin15",
            'X-Amz-Date' => now,
            'Host' => datastore['RHOST'],
            'X-Amz-Content-Sha256' => body_digest,
            'Accept' => '*/*'
          }
          headers['X-Amz-Security-Token'] = creds['Token'] if creds['Token']
          sign_headers = ['Content-Type', 'Host', 'User-Agent', 'X-Amz-Content-Sha256', 'X-Amz-Date']
          auth_headers = headers.select { |k, _| sign_headers.include?(k) }
          headers['Authorization'] = auth(creds, service, auth_headers, body_digest, now)
          headers
        end

        def print_hsh(hsh)
          hsh.each do |key, value|
            print_warning "#{key}: #{value}"
          end
        end

        def print_results(doc, action)
          response = "#{action}Response"
          result = "#{action}Result"
          resource = /[A-Z][a-z]+([A-Za-z]+)/.match(action)[1]

          if doc["ErrorResponse"] && doc["ErrorResponse"]["Error"]
            print_error doc["ErrorResponse"]["Error"]["Message"]
            return nil
          end

          idoc = doc[response] if doc[response]
          idoc = idoc[result] if idoc[result]
          idoc = idoc[resource] if idoc[resource]

          if idoc["member"]
            idoc["member"].each do |x|
              print_hsh x
            end
          else
            print_hsh idoc
          end
          idoc
        end

        def call_api(creds, service, api_params)
          print_status("#{peer} - Connecting (#{datastore['RHOST']})...")
          body = body(api_params)
          body_length = body.length
          body_digest = hexdigest(body)
          begin
            res = send_request_raw(
              'method' => 'POST',
              'data' => body,
              'headers' => headers(creds, service, body_digest, body_length)
            )
            if res.nil?
              print_error "#{peer} did not respond"
            else
              Hash.from_xml(res.body)
            end
          rescue => e
            print_error e.message
          end
        end

        def call_iam(creds, api_params)
          api_params['Version'] = '2010-05-08' unless api_params['Version']
          call_api(creds, 'iam', api_params)
        end

        def call_ec2(creds, api_params)
          api_params['Version'] = '2015-10-01' unless api_params['Version']
          call_api(creds, 'ec2', api_params)
        end

        def call_sts(creds, api_params)
          api_params['Version'] = '2011-06-15' unless api_params['Version']
          call_api(creds, 'sts', api_params)
        end
      end
    end
  end
end
