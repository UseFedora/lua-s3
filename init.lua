local http = require'socket.http'
local hmac = require'resty.hmac'
local crypto = require("crypto")
local cjson = require("cjson")
local date = require("date") -- this is luadate

local function generateAuthHeaders(awsId, awsKey, awsToken, md5, type, destination)
   -- Thanks to https://github.com/jamesmarlowe/lua-resty-s3/, BSD license.
   -- Used to sign S3 requests.
   -- awsToken is optional.
   local id, key = awsId, awsKey
   local date = os.date("!%a, %d %b %Y %H:%M:%S +0000")
   local hm, err = hmac:new(key)
   local StringToSign = ("PUT"..string.char(10)..
                         md5..string.char(10)..
                         type..string.char(10)..
                         string.char(10).. -- passing date as an x-amz header
                         "x-amz-date:"..date..string.char(10)..
                         (awsToken and "x-amz-security-token:"..awsToken..string.char(10) or "")..
                         destination)
   headers, err = hm:generate_headers("AWS", id, "sha1", StringToSign)
   return headers, err
end

function getMetadataCredentials(role)
   -- Return temporary credentials for the given IAM and AWS role.
   -- See https://aws.amazon.com/blogs/aws/iam-roles-for-ec2-instances-simplified-secure-access-to-aws-service-apis-from-ec2/
   -- and https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/UsingIAM.html#UsingIAMrolesWithAmazonEC2Instances for details on how to set this up.
   local result = {}
   local _, resultCode, headers, statusLine = http.request{method = "GET",
                              url = "http://169.254.169.254/2014-11-05/meta-data/iam/security-credentials/"..role,
                              sink = ltn12.sink.table(result),
                        }
   if resultCode ~= 200 then
      error(string.format("Could not retrieve credentials for the IAM role '%s' from the AWS metadata service. Are you on AWS? Is your EC2 IAM role provisioning set up correctly? Error code: %d, returned: '%s'",
                          role,
                          resultCode,
                          table.concat(result)
                    ))
   end
   local js = cjson.decode(table.concat(result))
   function js.minutesTillExpiration()
      return (date(js.Expiration) - date(true)):spanminutes()
   end
   return js
end


--function s3_api(credentials, method,
local S3Bucket = {}
function S3Bucket:connect(config)
   -- config should contain the following fields:
   --   - awsId: The AWS ID
   --   - awsKey: The AWS Secret Key
   --   - awsRole: The EC2 Role, used when fetching credentials from
   --     the metadata service.
   --   - bucket: The name of the bucket to connect to

   -- If no AWS ID is set and no AWS Key is set, these credentials
   -- will be retrieved from the metadata service using the given awsRole.
   if not (config.awsId and config.awsKey) and not config.awsRole then
      error("S3Bucket: Need an AWS ID and key, or an AWS role.")
   end

   setmetatable(config, {__index = self})
   return config
end

function S3Bucket:getCachedCredentials()
   if not self.cachedCredentials or self.cachedCredentials.minutesTillExpiration() <= 15 then
      self.cachedCredentials = getMetadataCredentials(self.awsRole)
   end
   return self.cachedCredentials
end

function S3Bucket:getAwsCredentials()
   if self.awsId and self.awsKey then
      return self.awsId, self.awsKey
   else
      local c = self:getCachedCredentials()
      return c.AccessKeyId, c.SecretAccessKey, c.Token
   end
end

function S3Bucket:put(key, data)
   -- Try to upload 'data' (string) into 'key'
   -- Maximum file size is 5 GB.

   local awsId, awsKey, awsToken = self:getAwsCredentials()
   local bucketname = self.bucket
   local url = "https://"..bucketname..".s3.amazonaws.com/"..key
   -- 'enc' is a global function from hmac.lua that encodes the result
   -- in base64.
   local md5 = enc(crypto.digest("md5", data, true))
   local authHeaders = generateAuthHeaders(awsId, awsKey, awsToken,
                                         md5,
                                         "",
                                         "/"..bucketname.."/"..key)
   local body = {}
   local _, resultCode, headers, statusLine = http.request{method = "PUT",
                              url = url,
                              headers = {["x-amz-date"]=authHeaders.date,
                                         ["x-amz-security-token"]=awsToken, -- optional
                                         authorization=authHeaders.auth,
                                         ["content-md5"]=md5,
                                         ["content-length"]=#data},
                              source = ltn12.source.string(data),
                              sink = ltn12.sink.table(body),
                        }
   return {resultCode = resultCode,
           headers = headers,
           statusLine = statusLine,
           result = body
        }
end

function S3Bucket:get(key, sink)
   -- Try to download destination to the given LT12 source.
   local awsId, awsKey, awsToken = self:getAwsCredentials()
   local bucketname = self.bucket
   local url = "https://"..bucketname..".s3.amazonaws.com/"..key
   -- 'enc' is a global function from hmac.lua that encodes the result
   -- in base64.
   local authHeaders = generateAuthHeaders(awsId, awsKey, awsToken,
                                         nil,
                                         "",
                                         "/"..bucketname.."/"..destination)
   local downloadAsString = not sink
   local body
   if downloadAsString then
      body = {}
      sink = lt12.sink.table(body)
   end
   local _, resultCode, headers, statusLine = http.request{method = "GET",
                              url = url,
                              headers = {["x-amz-date"]=authHeaders.date,
                                         ["x-amz-security-token"]=awsToken, -- optional
                                         authorization=authHeaders.auth,
                                      },
                              sink = sink
                        }
   if downloadAsString then
      if resultCode ~= 200 then
         error(string.format("S3 result: %d, %s", resultCode, table.concat(body))
      end
      return table.concat(body)
   else
      return {resultCode = resultCode,
              headers = headers,
              statusLine = statusLine,
           }
   end
end

-- function get_bucket(awsId, awsKey, bucketname, key, sink)

-- end

return S3Bucket