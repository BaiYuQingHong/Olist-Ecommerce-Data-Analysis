create database
if not exists olist_analysis;
  use olist_analysis;
  
  #### 查询2017年每个月的总销售额GMV
  # 查询2017年每个订单的销售额(订单价格+运费)与日期
  with order_gmv as (
    select
      oi.price + oi.freight_value as total,
      str_to_date(o.order_purchase_timestamp, '%Y-%m-%d %H:%i:%s') as purchase_time -- 转成时间格式
    from
      olist_order_items_dataset as oi
      join olist_orders_dataset as o on o.order_id = oi.order_id
    where
      o.order_purchase_timestamp like "2017%" -- 导入时间是字符串
      and o.order_status = 'delivered'
  )
  # 计算2017年每个月的总销售额GMV = sum(price + freight)
  select
    month(purchase_time) as month2017,
    round(sum(total), 2) as GMV
  from
    order_gmv
  group by
    month2017
  order by
    month2017 asc;
    
    
    
    
  #### 统计2017年销售额最高的Top5商品品类，并显示对应的英文品类名
  # 查询2017年每个订单的销售额(订单价格+运费)与对应的英文品类名
  with order_gmv as (
    select
      op.product_category_name as category,
      oi.price + oi.freight_value as total
    from
      olist_order_items_dataset as oi
      join olist_orders_dataset as o on o.order_id = oi.order_id
      join olist_products_dataset as op on op.product_id = oi.product_id
    where
      o.order_purchase_timestamp like "2017%" -- 导入时间是字符串
      and o.order_status = 'delivered'
  ),
  # 查询2017年每个品类的总销售额和top5商品
  top5_gmv as (select category, round(sum(total), 2) as category_total from order_gmv group by category order by category_total desc limit 5)
  # 将2017年销售额top5的品类与英文名对应
  select
    category,
    top5_gmv.category_total,
    pt.product_category_name_english as english_name
  from
    top5_gmv
    join product_category_name_translation as pt on pt.product_category_name = top5_gmv.category
  where
    category is not null -- 过滤掉缺失品类的数据
  order by
    top5_gmv.category_total desc;
    
    
    
    
  ### 计算2017年各月的“复购率”
  with purchase_month as (
    -- 第一步：每个用户每月的购买记录（去重）
    select distinct
      oc.customer_unique_id,
      date_format(str_to_date(o.order_purchase_timestamp, '%Y-%m-%d %H:%i:%s'), '%Y-%m') as purchase_month
    from
      olist_orders_dataset as o
      join olist_customers_dataset as oc on o.customer_id = oc.customer_id
    where
      o.order_purchase_timestamp >= '2017-01-01'
      and o.order_purchase_timestamp < '2018-02-01'
      and o.order_status = 'delivered'
  ),
  repurchase_detail as (
    -- 第二步：找出连续两个月都有购买的用户明细
    select
      a.purchase_month as current_month,
      a.customer_unique_id
    from
      purchase_month as a
      join purchase_month as b on a.customer_unique_id = b.customer_unique_id
      -- 修正核心错误：将 '2017-01' 拼成 '2017-01-01'，加一个月得到 '2017-02-01'，再格式化回 '2017-02'
      and date_format(date_add(str_to_date(concat(a.purchase_month, '-01'), '%Y-%m-%d'), interval 1 month), '%Y-%m') = b.purchase_month
  ),
  monthly_total as ( -- 第三步：统计每个月总共有多少独立用户购买（分母）
    select purchase_month, count(distinct customer_unique_id) as total_users from purchase_month group by purchase_month),
  monthly_repurchase as ( -- 第四步：统计每个月有多少用户下个月复购（分子）
    select current_month, count(distinct customer_unique_id) as repurchase_users from repurchase_detail group by current_month)
  -- 第五步：计算复购率
  select
    mt.purchase_month as 月份,
    mt.total_users as 当月总客数,
    coalesce(mr.repurchase_users, 0) as 次月复购客数,
    round(coalesce(mr.repurchase_users, 0) / mt.total_users * 100, 2) as 复购率百分比
  from
    monthly_total as mt
    left join monthly_repurchase as mr on mt.purchase_month = mr.current_month
  where
    mt.purchase_month like '2017%'
  order by
    mt.purchase_month asc;
    
    
    
### 构建 RFM 用户分层模型
with user_rfm_raw as (
-- 第一步：计算每个用户的原始 R、F、M
    select 
        oc.customer_unique_id,
        -- R: 最近一次购买距今的天数（最后一天作为基准）
        datediff('2018-09-01', max(str_to_date(o.order_purchase_timestamp, '%Y-%m-%d %H:%i:%s'))) as recency,
        -- F: 消费频次（用户下了多少个不同的订单）
        count(distinct o.order_id) as frequency,
        -- M: 消费总金额
        sum(oi.price + oi.freight_value) as monetary
    from olist_orders_dataset as o 
    join olist_customers_dataset as oc 
        on o.customer_id = oc.customer_id
    join olist_order_items_dataset as oi 
        on o.order_id = oi.order_id
    where o.order_status = 'delivered'
    group by oc.customer_unique_id
),
user_rfm_score as (
-- 第二步：给 R、F、M 打分（1-5分）
    select 
        customer_unique_id,
        recency,      -- 把原始值带上，方便最后查看
        frequency,    -- 把原始值带上，方便最后查看
        monetary,     -- 把原始值带上，外层才能 order by
        -- R值越小越好，所以用 6 - ntile(5) 来倒置分数
        6 - ntile(5) over (order by recency asc) as r_score,
        ntile(5) over (order by frequency asc) as f_score,
        ntile(5) over (order by monetary asc) as m_score
    from user_rfm_raw
)
-- 第三步：根据分数给用户打标签
select 
    customer_unique_id,
    recency,
    frequency,
    monetary,
    r_score,
    f_score,
    m_score,
    -- 简单组合：如果 R、F、M 都大于等于 4，就是高价值用户
    case 
        when r_score >= 4 and f_score >= 4 and m_score >= 4 then '重要价值客户'
        when r_score < 4 and f_score >= 4 and m_score >= 4 then '重要挽留客户'
        when r_score >= 4 and f_score < 4 and m_score < 4 then '新晋潜力客户'
        else '一般维持客户'
    end as user_segment
from user_rfm_score
order by monetary desc;














