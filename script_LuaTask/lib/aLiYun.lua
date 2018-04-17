--- 模块功能：阿里云物联网套件客户端功能.
-- 目前的产品节点类型仅支持“设备”，设备认证方式仅支持“一机一密”
-- @module aLiYun
-- @author openLuat
-- @license MIT
-- @copyright openLuat
-- @release 2018.04.16

require"log"
require"http"
require"mqtt"

module(..., package.seeall)

local sProductKey,sProductSecret,sGetDeviceNameFnc,sGetDeviceSecretFnc

local outQuene =
{
    SUBSCRIBE = {},
    PUBLISH = {},
}

local evtCb = {}

local function insert(type,topic,qos,payload,cbFnc,cbPara)
    table.insert(outQuene[type],{t=topic,q=qos,p=payload,cb=cbFnc,para=cbPara})
end

local function remove(type)
    if #outQuene[type]>0 then return table.remove(outQuene[type],1) end
end

local function procSubscribe(client)
    local i
    for i=1,#outQuene["SUBSCRIBE"] do
        if not client:subscribe(outQuene["SUBSCRIBE"][i].t,outQuene["SUBSCRIBE"][i].q) then
            return false,"procSubscribe"
        end
    end
    return true
end

local function procReceive(client)
    local r,data
    while true do
        r,data = client:receive(2000)
        --接收到数据
        if r and data~="timeout" then
            log.info("aLiYun.procReceive",data.topic,string.toHex(data.payload))
            --OTA消息
            if data.topic=="/ota/device/upgrade/"..sProductKey.."/"..sGetDeviceNameFnc() then
                if aLiYunOta and aLiYunOta.upgrade then
                    aLiYunOta.upgrade(data.payload)
                end
            --其他消息
            else    
                if evtCb["receive"] then evtCb["receive"](data.topic,data.qos,data.payload) end
            end
            
            --如果有等待发送的数据，则立即退出本循环
            if #outQuene["PUBLISH"]>0 then return true,"procReceive" end
        else
            break
        end
    end
	
    return data=="timeout" or r,"procReceive"
end

local function procSend(client)
    while #outQuene["PUBLISH"]>0 do
        local item = table.remove(outQuene["PUBLISH"],1)
        local result = client:publish(item.t,item.p,item.q)
        if item.cb then item.cb(result,item.para) end
        if not result then return false,"procSend" end
    end
    return true,"procSend"
end

function clientDataTask(host,tPorts,clientId,user,password)
    while true do
        while not socket.isReady() do sys.waitUntil("IP_READY_IND") end

        local mqttClient = mqtt.client(clientId,240,user,password)
        local portIdx = 0
        while true do
            portIdx = portIdx%(#tPorts)+1
            if mqttClient:connect(host,tonumber(tPorts[portIdx]),"tcp_ssl") then
                break
            end
            sys.wait(2000)
            portIdx = portIdx+1
        end

        if aLiYunOta and aLiYunOta.connectCb then aLiYunOta.connectCb(true,sProductKey,sGetDeviceNameFnc()) end
        if evtCb["connect"] then evtCb["connect"](true) end

        local result,prompt = procSubscribe(mqttClient)
        if result then
            local procs,k,v = {procReceive,procSend}
            while true do
                for k,v in pairs(procs) do
                    result,prompt = v(mqttClient)
                    if not result then log.warn("aLiYun.clientDataTask."..prompt.." error") break end
                end
                if not result then break end
            end
        else
            log.warn("aLiYun.clientDataTask."..prompt.." error")
        end

        while #outQuene["PUBLISH"]>0 do
            local item = table.remove(outQuene["PUBLISH"],1)
            if item.cb then item.cb(false,item.para) end
        end
        if aLiYunOta and aLiYunOta.connectCb then aLiYunOta.connectCb(false,sProductKey,sGetDeviceNameFnc()) end
        if evtCb["connect"] then evtCb["connect"](false) end

        mqttClient:disconnect()
        sys.wait(2000)
    end
end

local function authCbFnc(result,statusCode,head,body)
    log.info("aLiYun.authCbFnc",result,statusCode,body)
    sys.publish("ALIYUN_AUTH_IND",result,statusCode,body)
end

function clientAuthTask()
    while not socket.isReady() do sys.waitUntil("IP_READY_IND") end
    while true do
    
        local retryCnt = 0
        
        local data = "clientId"..sGetDeviceNameFnc().."deviceName"..sGetDeviceNameFnc().."productKey"..sProductKey
        local signKey = sGetDeviceSecretFnc()
        local sign = crypto.hmac_md5(data,data:len(),signKey,signKey:len())
        local body = "productKey="..sProductKey.."&sign="..sign.."&clientId="..sGetDeviceNameFnc().."&deviceName="..sGetDeviceNameFnc()
        
        while true do
            http.request("POST",
                     "https://iot-auth.cn-shanghai.aliyuncs.com/auth/devicename",
                     nil,{["Content-Type"]="application/x-www-form-urlencoded"},body,20000,authCbFnc)
                     
            local _,result,statusCode,body = sys.waitUntil("ALIYUN_AUTH_IND")
            --log.info("aLiYun.clientAuthTask1",result and statusCode=="200",body)
            if result and statusCode=="200" then
                local tJsonDecode,result = json.decode(body)
                --log.info("aLiYun.clientAuthTask2",result,tJsonDecode["message"],tJsonDecode["data"])
                if result and tJsonDecode["message"]=="success" and tJsonDecode["data"] and type(tJsonDecode["data"])=="table" then
                    --log.info("aLiYun.clientAuthTask3",tJsonDecode["data"]["iotId"],tJsonDecode["data"]["iotToken"])
                    if tJsonDecode["data"]["iotId"] and tJsonDecode["data"]["iotId"]~="" and tJsonDecode["data"]["iotToken"] and tJsonDecode["data"]["iotToken"]~="" then
                        local ports,host,returnMqtt = {}
                        if tJsonDecode["data"]["resources"] and type(tJsonDecode["data"]["resources"])=="table" then
                            if tJsonDecode["data"]["resources"]["mqtt"] then
                                returnMqtt,host = true,tJsonDecode["data"]["resources"]["mqtt"]["host"]
                                table.insert(ports,tJsonDecode["data"]["resources"]["mqtt"]["port"])
                            end
                        end
                        
                        sys.taskInit(clientDataTask,returnMqtt and host or sProductKey..".iot-as-mqtt.cn-shanghai.aliyuncs.com",#ports~=0 and ports or {1883},sGetDeviceNameFnc(),tJsonDecode["data"]["iotId"],tJsonDecode["data"]["iotToken"])	
                        return
                    end
                end
            end
            retryCnt = retryCnt+1
            if retryCnt==3 then
                break
            end
        end
        
        sys.wait(5000)
    end
end


--- 配置阿里云物联网套件的产品信息和设备信息
-- @string productKey，产品标识
-- @string[opt=nil] productSecret，产品密钥
-- @function getDeviceNameFnc，获取设备名称的函数
-- @function getDeviceSecretFnc，获取设备密钥的函数
-- @return nil
-- @usage
-- aLiYun.setup("b0FMK1Ga5cp",nil,getDeviceNameFnc,getDeviceSecretFnc)
function setup(productKey,productSecret,getDeviceNameFnc,getDeviceSecretFnc)
    sProductKey,sProductSecret,sGetDeviceNameFnc,sGetDeviceSecretFnc = productKey,productSecret,getDeviceNameFnc,getDeviceSecretFnc
    sys.taskInit(clientAuthTask)
end

--- 订阅主题
-- @param topic，string或者table类型，一个主题时为string类型，多个主题时为table类型，主题内容为UTF8编码
-- @param qos，number或者nil，topic为一个主题时，qos为number类型(0/1/2，默认0)；topic为多个主题时，qos为nil
-- @return nil
-- @usage
-- aLiYun.subscribe("/b0FMK1Ga5cp/862991234567890/get", 0)
-- aLiYun.subscribe({["/b0FMK1Ga5cp/862991234567890/get"] = 0, ["/b0FMK1Ga5cp/862991234567890/get"] = 1})
function subscribe(topic,qos)
	insert("SUBSCRIBE",topic,qos)
end

--- 发布一条消息
-- @string topic，UTF8编码的主题
-- @string payload，负载
-- @number[opt=0] qos，质量等级，0/1/2，默认0
-- @function[opt=nil] cbFnc，消息发布结果的回调函数
-- 回调函数的调用形式为：cbFnc(result,cbPara)。result为true表示发布成功，false或者nil表示订阅失败；cbPara为本接口中的第5个参数
-- @param[opt=nil] cbPara，消息发布结果回调函数的回调参数
-- @return nil
-- @usage
-- aLiYun.publish("/b0FMK1Ga5cp/862991234567890/update","test",0)
-- aLiYun.publish("/b0FMK1Ga5cp/862991234567890/update","test",1,cbFnc,"cbFncPara")
function publish(topic,payload,qos,cbFnc,cbPara)
    insert("PUBLISH",topic,qos,payload,cbFnc,cbPara)
end

--- 注册事件的处理函数
-- @string evt，事件
-- "connect"表示连接结果事件
-- "receive"表示接收到消息事件
-- @function cbFnc，事件的处理函数
-- 当evt为"connect"时，cbFnc的调用形式为：cbFnc(result)，result为true表示连接成功，false或者nil表示连接失败
-- 当evt为"receive"时，cbFnc的调用形式为：cbFnc(topic,qos,payload)，topic为UTF8编码的主题(string类型)，qos为质量等级(number类型)，payload为原始编码的负载(string类型)
-- @return nil
-- @usage
-- aLiYun.on("b0FMK1Ga5cp",nil,getDeviceNameFnc,getDeviceSecretFnc)
function on(evt,cbFnc)
	evtCb[evt] = cbFnc
end
