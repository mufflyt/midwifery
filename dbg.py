import re,html,urllib.parse,urllib.request,http.cookiejar
B="https://ams.amcbmidwife.org/amcbssa/"
op=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
op.addheaders=[("User-Agent","Mozilla/5.0")]
f=op.open(B+"f?p=AMCBSSA:17800").read().decode("utf8","replace")
S=re.search(r'name="p_instance" value="(\d+)"',f).group(1)
R=re.search(r"apex\.widget\.report\.paginate\('(\d+)'",f).group(1)
def q(cert="CNM",num="",last=""):
    v=",".join(urllib.parse.quote(x) for x in [cert,num,last])
    d=op.open(f"{B}f?p=500:17800:{S}::NO::P17800_CERT,P17800_CERT_NUMBER,P17800_LASTNAME,P17800_SEARCH_FLG:{v},Y").read().decode("utf8","replace")
    tot=sum(int(n) for n in re.findall(r"Total : (\d+)",d))
    print(f"cert={cert!r} num={num!r} last={last!r} -> {tot}")
    return d
d=q(last="smith")
nums=[]
for tr in re.findall(r"<tr[^>]*>(.*?)</tr>",d,re.S):
    c=[re.sub(r'\s+',' ',html.unescape(re.sub(r'<[^>]+>',' ',x))).strip() for x in re.findall(r"<td[^>]*>(.*?)</td>",tr,re.S)]
    if len(c)==10: nums.append(c[1])
bare=[n for n in nums if n.isdigit()]
print("sample bare numbers:",bare[:5])
b=bare[0]
q(num=b); q(num=b[:3]); q(num=b[0]+"_"*(len(b)-1)); q(num=b[:2]+"_"*(len(b)-2)); q(num="_"); q(num="%")
